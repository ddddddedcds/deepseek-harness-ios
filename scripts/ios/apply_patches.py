#!/usr/bin/env python3
"""Apply all dsh-ios cross-compile patches to a node-v22.23.2 source tree.

Usage: python3 apply_patches.py <node-source-dir>
Idempotent: safe to re-run.

References (technique lineage, not code copy):
  - davghz/node22-ios-source  -- Node 22 iOS cross-compile patchset (darwin JIT path)
  - j0shua-SYSON/node-ios    -- iOS Node build + native module (node-pty) adaptation
  - imcynic (Node 18 iOS)     -- darwin-style JIT memory path (drop MAP_JIT, direct PROT_EXEC)
The 7 patches below are written independently, building on that community lineage.
"""
import sys
import os
import shutil
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent  # 仓库根
SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "node-v22.23.2")

applied = []
skipped = []


def edit(path, old, new, note):
    """Replace old with new in path (relative to SRC); skip if already applied."""
    p = SRC / path
    if not p.exists():
        skipped.append(f"{path}: 不存在")
        return
    s = p.read_text(encoding="utf-8")
    if new in s and old not in s:
        skipped.append(f"{path}: 已应用")
        return
    if old not in s:
        skipped.append(f"{path}: 未找到目标文本")
        return
    p.write_text(s.replace(old, new, 1), encoding="utf-8")
    applied.append(path)


# 1. mach_vm.h shim 已随仓库提供（ios-sdk-shim/mach/mach_vm.h），通过 -I 注入。

# 2. c-ares: macOS 专属头
edit(
    "deps/cares/config/darwin/ares_config.h",
    "#define HAVE_SYS_RANDOM_H 1",
    "/* #undef HAVE_SYS_RANDOM_H */",
    "c-ares: 禁用 macOS 专属 sys/random.h（改走 arc4random_buf）",
)

# 3. node.gypi: CoreFoundation/Security framework + NODE_PLATFORM=darwin
edit(
    "node.gypi",
    "    [ 'OS==\"mac\"', {",
    "    [ 'OS in \"mac ios\"', {",
    "node.gypi: CoreFoundation/Security 链接对 ios 生效",
)

# 4. crypto_context.cc: macOS 专属 SecTrustSettings（两处）
edit(
    "src/crypto/crypto_context.cc",
    "#ifdef __APPLE__\nTrustStatus IsTrustDictionaryTrustedForPolicy(",
    "#if defined(__APPLE__) && !defined(__aarch64__)\nTrustStatus IsTrustDictionaryTrustedForPolicy(",
    "crypto_context: 排除 iOS（SecTrustSettings 仅 macOS）",
)
edit(
    "src/crypto/crypto_context.cc",
    "#ifdef __APPLE__\n  ReadMacOSKeychainCertificates(&system_store_certs);\n#endif",
    "#if defined(__APPLE__) && !defined(__aarch64__)\n  ReadMacOSKeychainCertificates(&system_store_certs);\n#endif",
    "crypto_context: iOS 系统证书库留空",
)

# 5. v8.gyp: trap handler 源提升到 target 顶层（不依赖 maglev）
trap_block = """        # iOS port: trap handler sources must NOT be gated behind
        # v8_enable_maglev (maglev is off on iOS); evaluate at target level.
        ['v8_enable_webassembly==1', {
          'conditions': [
            ['((_toolset=="host" and host_arch=="arm64" or _toolset=="target" and target_arch=="arm64") and (OS in "linux mac ios openharmony")) or ((_toolset=="host" and host_arch=="x64" or _toolset=="target" and target_arch=="x64") and (OS in "linux mac ios openharmony"))', {
              'sources': [
                '<(V8_ROOT)/src/trap-handler/handler-inside-posix.cc',
                '<(V8_ROOT)/src/trap-handler/handler-outside-posix.cc',
              ],
            }],
            ['(_toolset=="host" and host_arch=="x64" or _toolset=="target" and target_arch=="x64") and (OS in "linux mac ios win openharmony")', {
              'sources': [
                '<(V8_ROOT)/src/trap-handler/handler-outside-simulator.cc',
              ],
            }],
          ],
        }],
"""
edit(
    "tools/v8_gypfiles/v8.gyp",
    "      'conditions': [\n        ['v8_enable_snapshot_compression==1', {",
    "      'conditions': [\n" + trap_block + "        ['v8_enable_snapshot_compression==1', {",
    "v8.gyp: trap handler 条件提升到 target 顶层",
)

# 5b. v8.gyp: x64-host/win 分支 OS 列表补 ios
edit(
    "tools/v8_gypfiles/v8.gyp",
    """'(_toolset=="host" and host_arch=="x64" or _toolset=="target" and target_arch=="x64") and (OS in "linux mac win openharmony")'""",
    """'(_toolset=="host" and host_arch=="x64" or _toolset=="target" and target_arch=="x64") and (OS in "linux mac ios win openharmony")'""",
    "v8.gyp: handler-outside-simulator 条件补 ios",
)

# 6. platform-posix.cc: 移除 MAP_JIT（越狱机走直接 PROT_EXEC 老式 JIT）
old_mapjit = """#if V8_OS_DARWIN
  // MAP_JIT is required to obtain writable and executable pages when the
  // hardened runtime/memory protection is enabled, which is optional (via code
  // signing) on Intel-based Macs but mandatory on Apple silicon ones. See also
  // https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon.
  if (access == OS::MemoryPermission::kNoAccessWillJitLater) {
    flags |= MAP_JIT;
  }
#endif  // V8_OS_DARWIN"""
new_mapjit = """#if V8_OS_DARWIN
  // iOS port (jailbroken): do NOT use MAP_JIT. On jailbroken iOS the kernel
  // allows direct PROT_EXEC mappings (amfid/codesign patched), while MAP_JIT
  // pages stay non-executable unless the process's JIT entitlement is honored
  // (CS_JIT) — unreliable for ldid-signed CLI binaries. Skipping MAP_JIT makes
  // the code range executable via plain mprotect, matching nodejs-mobile/imcynic.
#endif  // V8_OS_DARWIN"""
edit("deps/v8/src/base/platform/platform-posix.cc", old_mapjit, new_mapjit,
     "platform-posix: 移除 MAP_JIT，走越狱机老式 JIT 路径")

# 6b. MAP_NORESERVE 在本机 mmap 失败（实测 MAP_FAILED），会破坏代码区保留
old_nr = """#if !V8_OS_AIX && !V8_OS_FREEBSD && !V8_OS_QNX
    flags |= MAP_NORESERVE;
#endif  // !V8_OS_AIX && !V8_OS_FREEBSD && !V8_OS_QNX"""
new_nr = """#if !V8_OS_AIX && !V8_OS_FREEBSD && !V8_OS_QNX && !V8_OS_DARWIN
    // iOS port: MAP_NORESERVE mmap FAILS on jailbroken iOS (MAP_FAILED),
    // breaking V8's code range / sandbox reservation. Skip it.
    flags |= MAP_NORESERVE;
#endif  // !V8_OS_AIX && !V8_OS_FREEBSD && !V8_OS_QNX && !V8_OS_DARWIN"""
edit("deps/v8/src/base/platform/platform-posix.cc", old_nr, new_nr,
     "platform-posix: 移除 MAP_NORESERVE（本机 mmap 失败）")

print("已应用:", len(applied))
for a in applied:
    print("  +", a)
print("跳过:", len(skipped))
for s in skipped:
    print("  -", s)
sys.exit(0 if skipped and all("已应用" in x for x in skipped) or not skipped else 1)

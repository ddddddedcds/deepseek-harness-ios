#!/bin/sh
# build-dsh-ios.sh — bundle DeepSeek Harness for iOS:
#   * cross-compile node-pty addon (pty.node + spawn-helper, arm64 iOS)
#   * npm-install @deepseek-ai/dsh (scripts disabled)
#   * apply JS shims (sharp / require-builtin)
#   * package dsh-ios .deb (self-contained, no device-side npm)
#
# Usage: ./scripts/build-dsh-ios.sh   (requires nodejs deb built first: scripts/build-node-ios.sh)
# Output: dist/dsh-ios_0.1.1-rc.2-1_iphoneos-arm64.deb
set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mkdir -p dist
WORK=/tmp/dsh-ios-work
rm -rf "$WORK"
mkdir -p "$WORK"

NODE_VER=22.23.2
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SHIM="$ROOT/ios-sdk-shim"

echo "== [1/5] 下载 node headers（node-pty 编译用）=="
curl -sL -o /tmp/node-hdrs.tar.gz "https://nodejs.org/download/release/v$NODE_VER/node-v$NODE_VER-headers.tar.gz"
tar xzf /tmp/node-hdrs.tar.gz -C "$WORK"
mv "$WORK/node-v$NODE_VER" "$WORK/node-headers"

echo "== [2/5] 交叉编译 node-pty =="
mkdir -p "$WORK/node-pty" && cd "$WORK/node-pty"
npm pack node-pty@1.1.0 --silent >/dev/null
tar xzf node-pty-1.1.0.tgz && mv package node-pty-src && cd node-pty-src
npm install --ignore-scripts --no-audit --no-fund --silent >/dev/null 2>&1 || true
# iOS clang 包装（过滤 macOS 专属 -mmacosx-version-min）
cat > /tmp/clang-ios <<EOF
#!/bin/sh
args=""
for a in "\$@"; do
  case "\$a" in
    -mmacosx-version-min*) ;;
    *) args="\$args \$a" ;;
  esac
done
exec /usr/bin/clang -target arm64-apple-ios16.0 -isysroot "$SDK" -miphoneos-version-min=16.0 \$args
EOF
cat > /tmp/clang++-ios <<EOF
#!/bin/sh
args=""
for a in "\$@"; do
  case "\$a" in
    -mmacosx-version-min*) ;;
    *) args="\$args \$a" ;;
  esac
done
exec /usr/bin/clang++ -target arm64-apple-ios16.0 -isysroot "$SDK" -miphoneos-version-min=16.0 -stdlib=libc++ \$args
EOF
chmod +x /tmp/clang-ios /tmp/clang++-ios
# 打 iOS 兼容补丁（libproc/kqueue 等守卫）
python3 - <<'PY'
import re
f = "src/unix/pty.cc"
s = open(f).read()
# libproc.h is macOS-only; guard the include (balanced #if/#endif).
s = s.replace('#elif defined(__APPLE__)\n#include <libproc.h>',
              '#elif defined(__APPLE__)\n#if !defined(__aarch64__)\n#include <libproc.h>\n#endif')
# extern "C" pthread externs are macOS-only APIs; guard them, but keep
# HANDLE_EINTR defined unconditionally -- the kqueue wait block below still
# uses it on iOS. (Previous version nested an extra #if without a matching
# #endif, which unbalanced the preprocessor and hid HANDLE_EINTR.)
old_block = '''#if defined(__APPLE__)
extern "C" {
// Changes the current thread's directory to a path or directory file
// descriptor. libpthread only exposes a syscall wrapper starting in
// macOS 10.12, but the system call dates back to macOS 10.5. On older OSes,
// the syscall is issued directly.
int pthread_chdir_np(const char* dir) API_AVAILABLE(macosx(10.12));
int pthread_fchdir_np(int fd) API_AVAILABLE(macosx(10.12));
}

#define HANDLE_EINTR(x) ({ \\
  int eintr_wrapper_counter = 0; \\
  decltype(x) eintr_wrapper_result; \\
  do { \\
    eintr_wrapper_result = (x); \\
  } while (eintr_wrapper_result == -1 && errno == EINTR && \\
           eintr_wrapper_counter++ < 100); \\
  eintr_wrapper_result; \\
})
#endif'''
new_block = '''#if defined(__APPLE__) && !defined(__aarch64__)
extern "C" {
// Changes the current thread's directory to a path or directory file
// descriptor. libpthread only exposes a syscall wrapper starting in
// macOS 10.12, but the system call dates back to macOS 10.5. On older OSes,
// the syscall is issued directly.
int pthread_chdir_np(const char* dir) API_AVAILABLE(macosx(10.12));
int pthread_fchdir_np(int fd) API_AVAILABLE(macosx(10.12));
}
#endif

#define HANDLE_EINTR(x) ({ \\
  int eintr_wrapper_counter = 0; \\
  decltype(x) eintr_wrapper_result; \\
  do { \\
    eintr_wrapper_result = (x); \\
  } while (eintr_wrapper_result == -1 && errno == EINTR && \\
           eintr_wrapper_counter++ < 100); \\
  eintr_wrapper_result; \\
})'''
assert old_block in s, "pty.cc extern/HANDLE_EINTR block not found -- patch text mismatch"
s = s.replace(old_block, new_block)
# pty_getproc depends on libproc; guard its declaration + uses on iOS.
s = s.replace('#if defined(__APPLE__)\nstatic char *\npty_getproc(int);',
              '#if defined(__APPLE__) && !defined(__aarch64__)\nstatic char *\npty_getproc(int);')
s = s.replace('#if defined(__APPLE__)\n  if (info.Length() != 1 ||',
              '#if defined(__APPLE__) && !defined(__aarch64__)\n  if (info.Length() != 1 ||')
s = s.replace('#elif defined(__APPLE__)\n\nstatic char *\npty_getproc(int fd) {',
              '#elif defined(__APPLE__) && !defined(__aarch64__)\n\nstatic char *\npty_getproc(int fd) {')
open(f, "w").write(s)
print("pty.cc patched")
PY
export CC=/tmp/clang-ios CXX=/tmp/clang++-ios CFLAGS="-DNAPI_VERSION=8" CXXFLAGS="-DNAPI_VERSION=8"
npx --yes node-gyp@10 rebuild --nodedir="$WORK/node-headers" --arch=arm64 >"$WORK/node-pty-build.log" 2>&1 || {
  echo "node-pty 编译失败，详见 $WORK/node-pty-build.log:"; tail -40 "$WORK/node-pty-build.log"; exit 1; }
ls build/Release/pty.node build/Release/spawn-helper >/dev/null 2>&1 || { echo "node-pty 产物缺失"; exit 1; }

echo "== [3/5] npm 安装 @deepseek-ai/dsh（跳过原生构建）=="
mkdir -p "$WORK/dsh" && cd "$WORK/dsh"
npm init -y >/dev/null 2>&1
npm_config_ignore_scripts=true npm_config_fund=false npm_config_audit=false \
  npm install @deepseek-ai/dsh@latest --no-audit --no-fund --silent >/dev/null 2>&1

echo "== [4/5] 应用 iOS addon + shims =="
NM="$WORK/dsh/node_modules"
mkdir -p "$NM/node-pty/build/Release"
cp "$WORK/node-pty/node-pty-src/build/Release/pty.node" "$NM/node-pty/build/Release/"
cp "$WORK/node-pty/node-pty-src/build/Release/spawn-helper" "$NM/node-pty/build/Release/"
chmod 755 "$NM/node-pty/build/Release/spawn-helper"
rm -rf "$NM/node-pty/prebuilds" "$NM/@img"
# sharp 双入口 shim（exports 把 ESM import 路由到 index.mjs）
cat > "$NM/sharp/dist/index.cjs" <<'EOF'
"use strict";
function u(){throw new Error("sharp is not available on this iOS build: image attachment processing is disabled");}
u.format={};u.versions={sharp:"0.0.0-ios-shim"};u.simd=false;u.concurrency=1;u.cache=()=>u;u.cacheable=true;
module.exports=u;module.exports.default=u;
EOF
cat > "$NM/sharp/dist/index.mjs" <<'EOF'
function u(){throw new Error("sharp is not available on this iOS build: image attachment processing is disabled");}
u.format={};u.versions={sharp:"0.0.0-ios-shim"};u.simd=false;u.concurrency=1;u.cache=()=>u;u.cacheable=true;
export default u;
EOF
cat > "$NM/node-addon-require-builtin/lib/index.js" <<'EOF'
"use strict";
function requireBuiltin(id){return require(id);}
function isAllowedInternalId(){return true;}
function getBindingInfo(){return {native:false,addon:null};}
exports.requireBuiltin=requireBuiltin;exports.isAllowedInternalId=isAllowedInternalId;exports.getBindingInfo=getBindingInfo;
exports.default={requireBuiltin,isAllowedInternalId,getBindingInfo};
EOF

echo "== [5/5] 打包 dsh-ios deb =="
DEB=/tmp/dsh-deb
rm -rf "$DEB" && mkdir -p "$DEB/DEBIAN" "$DEB/var/jb/usr/local/bin" "$DEB/var/jb/usr/local/lib"
cp -a "$NM" "$DEB/var/jb/usr/local/lib/node_modules"
ln -s ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$DEB/var/jb/usr/local/bin/dsh"
cat > "$DEB/var/jb/usr/local/bin/dsh-ios" <<'EOF'
#!/bin/sh
export DSH_HOME="${DSH_HOME:-/var/mobile/.dsh}"
export PATH="/var/jb/usr/local/bin:$PATH"
# --predictable --single-threaded: required on iOS. Without them the V8 W^X
# page-flip races with JIT and crashes with SIGBUS (see docs/ios-port.md).
exec /var/jb/usr/local/bin/node --expose-internals --predictable --single-threaded /var/jb/usr/local/bin/dsh web "$@"
EOF
chmod 755 "$DEB/var/jb/usr/local/bin/dsh-ios"
cat > "$DEB/DEBIAN/control" <<'CTRL'
Package: dsh-ios
Name: DeepSeek Harness for iOS
Version: 0.1.1-rc.2-1
Architecture: iphoneos-arm64
Maintainer: dsh-ios port
Section: Development
Depends: nodejs (>= 22.19.0)
Description: DeepSeek Harness (dsh) for jailbroken iOS. Bundles the full CLI with cross-compiled node-pty (real PTY) and JS shims for sharp / require-builtin. Self-contained: no npm needed on the device. Launch with "dsh-ios".
CTRL
cat > "$DEB/DEBIAN/postinst" <<'CTRL'
#!/bin/sh
P=/var/jb/usr/local
ENT="$P/lib/nodejs/entitlements.plist"
REL="$P/lib/node_modules/node-pty/build/Release"
LOG=/var/mobile/.dsh/postinst.log
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log(){ echo "[dsh-ios postinst $(date +%H:%M:%S)] $*" >> "$LOG" 2>/dev/null; }
if command -v ldid >/dev/null 2>&1; then
  [ -f "$ENT" ] || ENT=""
  for f in "$REL/pty.node" "$REL/spawn-helper"; do
    [ -f "$f" ] || continue
    if [ -n "$ENT" ]; then
      ldid -S"$ENT" "$f" >>"$LOG" 2>&1 && log "signed $f OK" || { echo "ERROR: ldid -S $f FAILED" >&2; log "ERROR: ldid -S $f FAILED"; }
    else
      ldid -S "$f" >>"$LOG" 2>&1 && log "signed $f OK (no entitlements)" || { echo "ERROR: ldid -S $f FAILED" >&2; log "ERROR: ldid -S $f FAILED"; }
    fi
  done
  chmod 755 "$REL/spawn-helper" 2>/dev/null
else
  echo "ERROR: ldid not found - node-pty addons left UNSIGNED" >&2
  log "ERROR: ldid not found"
fi
# trustcache: AMFI needs the addons registered or they SIGKILL on load.
if command -v jbctl >/dev/null 2>&1; then
  for f in "$REL/pty.node" "$REL/spawn-helper"; do
    [ -f "$f" ] || continue
    jbctl trustcache add "$f" >>"$LOG" 2>&1 && log "trustcache add $f OK" || log "WARN: jbctl trustcache add $f failed"
  done
else
  log "WARN: jbctl not found - trustcache registration skipped"
fi
exit 0
CTRL
chmod 755 "$DEB/DEBIAN/postinst"
dpkg-deb -b --root-owner-group -Zgzip "$DEB" "$ROOT/dist/dsh-ios_0.1.1-rc.2-1_iphoneos-arm64.deb" >/dev/null
echo "✅ $ROOT/dist/dsh-ios_0.1.1-rc.2-1_iphoneos-arm64.deb"

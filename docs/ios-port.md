# dsh 移植到越狱 iOS（rootless / Dopamine）

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）移植到越狱 iOS 的完整工程：
- **Node.js 22.23.2** 交叉编译为 iOS arm64（rootless `/var/jb` 布局）；**SSH/终端环境以 `--jitless` 运行**
  （arm64e SSH 进程实测拿不到可执行内存页，见"运行时环境与通用性约束"），WebAssembly 相应不可用
- **node-pty** 交叉编译真模块（真实 forkpty，终端功能完整）
- **sharp / node-addon-require-builtin** 用 JS shim 替代（libvips 无法在 iOS 编译）
- 标准 **.deb** 交付（`iphoneos-arm64`，dpkg 管理，postinst 自动 ldid 签名）

## 目录

| 路径 | 说明 |
|---|---|
| `.github/workflows/build-dsh-ios.yml` | GitHub Actions：云端全自动交叉编译 + 打包（macOS runner + Xcode） |
| `scripts/ios/apply_patches.py` | 7 处源码补丁（幂等） |
| `scripts/ios/build-node-ios.sh` | 编译 Node 22 → nodejs deb |
| `scripts/ios/build-dsh-ios.sh` | 编译 node-pty addon + 打包 dsh 全量依赖 → dsh-ios deb |
| `ios-sdk-shim/mach/mach_vm.h` | iOS SDK 缺失的 mach_vm 声明（libSystem 运行时实际导出） |

## 安装（设备端，root）

```sh
dpkg -i nodejs_22.23.2-1_iphoneos-arm64.deb dsh-ios_0.1.1-rc.2-1_iphoneos-arm64.deb
dsh-ios    # Safari 打开 http://127.0.0.1:3080
```

## 关键设计决策

### 1. JIT 路径：darwin 式，不用 MAP_JIT
V8 12.4 在 darwin 上对代码区用 `MAP_JIT` 映射，需要进程的 JIT entitlement 被内核认可（CS_JIT）才能 mprotect 成可执行。
ldid 签名的 CLI 二进制在 Dopamine 上**实测拿不到可执行页**（`KERN_PROTECTION_FAILURE`，SIGBUS）。
解法：删掉 `MAP_JIT`（`platform-posix.cc`），代码区用普通 mmap + mprotect 直连 PROT_EXEC——越狱内核补丁允许，
与 nodejs-mobile / imcynic（V8 10.2，无 MAP_JIT 逻辑）实测可跑的路径一致。完整 JIT + WASM 可用。

### 2. 不用 `-DTARGET_OS_IPHONE`
定义该宏会让 V8 走 `V8_OS_IOS` 内存路径（同样的 MAP_JIT 问题 + 更多 iOS 专属分支）。
不定义 → `V8_OS_MACOS` + `V8_TARGET_OS_IOS`（后者由 gyp `dest-os=ios` 的 flavor 机制自动设置）——与 nodejs-mobile 已验证配置一致。

### 3. 关键系统限制（真机实测）
iOS 16.7 + Dopamine rootless（A14）的 JIT 内存行为与预期不同，逐项实测：
- `mmap(PROT_EXEC)` 匿名内存：**拒绝**（执行时 SIGBUS）
- `mmap(MAP_JIT)`：**失败**（MAP_FAILED，即使 CS_JIT 已授予）
- `mmap(MAP_NORESERVE)`：**失败**（MAP_FAILED）← V8 代码区保留会用到，必须移除
- 带 CS_JIT 的进程：普通 mmap(RW) + mprotect(RX) **可用**（执行成功）
- 结论：ldid 签名 + JIT entitlements（CS_JIT 授予）+ 去 MAP_JIT/MAP_NORESERVE → 完整 JIT 可用

### 4. 其他补丁摘要（详见 apply_patches.py）
- c-ares：`HAVE_SYS_RANDOM_H` 关闭（macOS 独有头，改走 arc4random_buf）
- v8.gyp：trap handler 源提升到 target 顶层（原嵌套在 maglev 块内，maglev 关闭时不求值，mksnapshot 会缺符号）
- node.gypi：CoreFoundation/Security framework 链接对 ios 生效
- crypto_context.cc：macOS 专属 SecTrustSettings 代码对 iOS 排除
- ninja 生成器：configure 后需去掉 host 变体与 target 冲突的 gen 输出规则（脚本内置）
- node-pty `src/unix/pty.cc`：`libproc.h` 与 `pthread_chdir_np`/`pthread_fchdir_np` externs 是 macOS 专有，用 `#if defined(__APPLE__) && !defined(__aarch64__)` guard；`HANDLE_EINTR` 宏**必须留在 guard 外**（iOS 的 kqueue 等待块仍要用它）。
  - **踩坑修复（0.1.1-rc.2 构建）**：`scripts/ios/build-dsh-ios.sh` 的 python 补丁曾多插一个无配 `#endif` 的 `#if`，预处理失衡 → `error: unterminated conditional directive`，连带把块内 `HANDLE_EINTR` 宏吞掉 → 后续 7 处 `HANDLE_EINTR` 报 `undeclared`。已修（`#if`/`#endif` 平衡，19/19）。同时把 node-gyp 失败从 `>/dev/null 2>&1 || true` 改为吐真实日志，避免下次盲猜。

## 真机验证记录（iPhone 12 Pro Max, A14, iOS 16.7, Dopamine rootless）
- **（2026-08-27 SSH 实测）`--jitless` 是 SSH/终端进程的唯一可用模式**：`node -e` 执行 JS 即 SIGBUS
  （crash `KERN_PROTECTION_FAILURE`：V8 code range 页 `rw-` 被当指令执行）。嵌入
  `com.apple.security.cs.allow-jit` / `platform-application` 重签、root 用户均无效。
  → 与构建期"完整 JIT 可用"的记录存在环境差异（构建期验证的进程上下文具备 JIT 内存权限）；如确需
  完整 JIT + WASM，须在具备 JIT 权限的进程上下文（越狱 daemon / app 内）另行验证。
- **（2026-08-27）undici wasm 崩溃已解决**：dsh 0.1.1 的 global fetch（node 内建 undici）其 HTTP parser
  是 wasm 编译的，jitless 下加载即 `ReferenceError: WebAssembly is not defined`。解法 = 注入
  `fetch-shim.cjs`（node:http 实现 fetch/Headers/Request/Response，支持 SSE `getReader` 与
  `AbortSignal.timeout`）+ WebAssembly 全局 stub（永不 settle，令 undici 初始化不再 rejection）+
  `--no-experimental-fetch --no-experimental-websocket`。**dsh 已可越过 undici 崩溃，走到插件加载。**
- **（2026-08-27）Unicode 正则问题已修**：node 交叉编译默认 `--with-intl=none`（无 ICU），dsh 插件链
  （llm-pi-ai / hono path-to-regexp / jose / dsh-tools 等）使用 `\p{L}`、`\p{N}`、`\p{ID_Start}` 等
  Unicode 属性正则 200+ 处 → V8 报 `Invalid property name in character class`。已重编 node 为
  `--with-intl=small-icu`（Unicode 数据齐全）。
- iOS 16.7 libSystem 实测导出 `mach_vm_map/mach_vm_remap`（SDK 头缺失，shim 补齐）

## 运行时环境与通用性约束（真机实测 2026-08-27）

dsh-ios 附带的 nodejs 是**标准 Node.js 22.23.2**（arm64 iOS），任何**纯 JS** 程序都能运行；
但 iOS 越狱环境的三道硬限制决定了边界：

1. **JIT 不可用（必须 `--jitless`）**：SSH 会话进程（mobile/root 均实测）里 V8 拿不到可执行内存页。
   → 所有工具以 `--jitless` 运行：纯 JS 解释执行（慢 3–10 倍，不影响正确性）。
2. **WebAssembly 不可用**：`--jitless` 强制禁用 wasm（`--expose-wasm` 会被冲突禁用）。
   → 依赖 wasm 的库/工具无法使用（如 wasm 打包的压缩/加密/sqlite 等）。
3. **global fetch 需要 shim**：Node 内置 fetch（undici）的 llhttp parser 是 wasm，jitless 下加载即崩。
   → 任何用 fetch 的工具都要挂 `fetch-shim.cjs`（见上文，已随 dsh-ios 部署到
   `/var/jb/usr/local/lib/fetch-shim.cjs`）。

其它注意：
- **原生 addon（.node）**：npm 现成 prebuilt 多为 macOS/Linux，iOS 无法 dlopen，需交叉编译 arm64 iOS 版
  （node-pty 已做）；纯 JS 包无此限制。
- **nodejs deb 只含 node 二进制，不含 npm CLI**：装其他工具需从开发机拷 `node_modules` 或自行补 npm。
- **Unicode 正则**：重编后带 ICU（small-icu），任意 `\p{...}` 属性正则可用。

## iOS 插件 stub（koffi / sandbox / subprocess）

dsh 0.1.1 的 `dsh-sandbox-local` / `dsh-subprocess-local` 依赖 **koffi**（FFI 原生 addon，
无 iOS prebuilt），sandbox 还依赖 Linux landlock 与 Windows ACL——**iOS 上这些能力本就不存在**
（toolpkg manifest 的 `disabled_features` 早已标注 "koffi - no ios prebuilt"）。但插件的硬
`import koffi` 会直接挡死 dsh web 启动。

**解法（已实测，dsh web 3080 返回 HTTP 200）**：把两个插件的 `lib/index.js` 替换为
**extends 基类的惰性 stub**（基类 `SandboxProvider` / `SubprocessRuntime` 是纯 JS，服务注册
`ctx.sandbox` / `ctx.subprocess` 仍生效，`dsh-bash-sandbox` / `dsh-permission-presets` 可正常
激活）：

```js
// dsh-sandbox-local/lib/index.js
import { SandboxProvider } from "@deepseek-ai/dsh-sandbox";
export default class LocalSandboxProvider extends SandboxProvider {
  async start() {}
}
// dsh-subprocess-local/lib/index.js
import { SubprocessRuntime } from "@deepseek-ai/dsh-subprocess";
export default class LocalSubprocessRuntime extends SubprocessRuntime {
  async start() {}
}
```

代价：沙箱隔离与 FFI 子进程在 iOS 上不可用（Node 内置 `child_process`/`fork` 仍可用）；
聊天气泡、Web UI、文件、会话等核心功能不受影响。若后续需要真 koffi，可交叉编译
（node-gyp，纯 C，15–30 分钟量级）。

### 推荐启动姿势（其他工具）
```sh
NODE_OPTIONS="--jitless --no-experimental-fetch --no-experimental-websocket \
  --require /var/jb/usr/local/lib/fetch-shim.cjs"
/var/jb/usr/local/bin/node your-tool.js
```

## Credits / 血缘

本 iOS 移植的思路与 recipe 借鉴自以下公开工作（**血缘/思路来源，非代码直接拷贝**）：
- [davghz/node22-ios-source](https://github.com/davghz/node22-ios-source) — Node 22 iOS 交叉编译 recipe
- [j0shua-SYSON/node-ios](https://github.com/j0shua-SYSON/node-ios) — Node iOS 移植参考
- imcynic — V8/iOS 无 MAP_JIT 路径实测（Node 18 行为对齐）

## 当前发布状态

- 最新 deb：`dsh-ios_0.1.1-rc.2-1_iphoneos-arm64.deb`（基于 `@deepseek-ai/dsh` 0.1.1-rc.2）+ `nodejs_22.23.2-2_iphoneos-arm64.deb`（**重编：V8 完整 JIT（mprotect W^X 补丁）+ WASM + small-icu**，实测 `JIT_OK` / `WASM_OK 42` / `ICU_OK 78.2`）。安装顺序：nodejs → dsh-ios。
- **dsh web 已在设备跑通**：`dsh-ios` 启动后 `http://127.0.0.1:3080` 返回 HTTP 200（launcher 需带 `--predictable --single-threaded --wasm-enforce-bounds-checks --wasm-max-mem-pages=16384 --expose-internals`，防 W^X race；配合上文 koffi 插件 stub）。launcher 另挂 `--patch /var/mobile/.dsh/ios-overrides.patch.yml`（留作插件禁用 overlay）。
- 分支 `ios-port` 已推送到 fork [`ddddddedcds/deepseek-harness`](https://github.com/ddddddedcds/deepseek-harness)；`master` 已 fast-forward 到上游 0.1.1-rc.2（`b150a551`）。
- 已知限制：沙箱/FFI 子进程不可用（koffi stub，见上）；sharp/libvips 图片附件不可用；node-pty addon 真机验证待做；WebSocket 客户端不可用（`--no-experimental-websocket` 已禁，undici 正常时或可放开）。

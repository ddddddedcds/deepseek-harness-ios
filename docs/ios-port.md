# dsh 移植到越狱 iOS（rootless / Dopamine）

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）移植到越狱 iOS 的完整工程：
- **Node.js 22.23.2** 交叉编译为 iOS arm64（rootless `/var/jb` 布局），走 **darwin 式 JIT 路径**（完整 JIT + WASM）
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
dpkg -i nodejs_22.23.2-1_iphoneos-arm64.deb dsh-ios_0.1.0-rc.6-1_iphoneos-arm64.deb
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

### 3. 其他补丁摘要（详见 apply_patches.py）
- c-ares：`HAVE_SYS_RANDOM_H` 关闭（macOS 独有头，改走 arc4random_buf）
- v8.gyp：trap handler 源提升到 target 顶层（原嵌套在 maglev 块内，maglev 关闭时不求值，mksnapshot 会缺符号）
- node.gypi：CoreFoundation/Security framework 链接对 ios 生效
- crypto_context.cc：macOS 专属 SecTrustSettings 代码对 iOS 排除
- ninja 生成器：configure 后需去掉 host 变体与 target 冲突的 gen 输出规则（脚本内置）

## 真机验证记录（iPhone 12 Pro Max, A14, iOS 16.7, Dopamine rootless）
- `--jitless` 可跑（但 undici 需 WASM → 不可用）
- 移除 MAP_JIT 后完整 JIT 正常（与 imcynic Node 18 行为一致）
- iOS 16.7 libSystem 实测导出 `mach_vm_map/mach_vm_remap`（SDK 头缺失，shim 补齐）

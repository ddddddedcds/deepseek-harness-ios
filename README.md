# DeepSeek Harness

English | [中文](README.zh.md)

DeepSeek Harness (`dsh`) is an open-source agent harness developed by [DeepSeek AI](https://deepseek.com).

It uses an architecture where **everything is a plugin**, and is powered by [Cordis](https://github.com/cordiverse/cordis), whose design is described in [_A Programming Paradigm for Spatiotemporal Composability_](https://github.com/cordiverse/paper).

## Developer preview

DeepSeek Harness is currently in _developer preview_ and is iterating rapidly. **THERE WILL BE COMPATIBILITY-BREAKING CHANGES.**

## Run

### Run from `npm`

Install `Node.js`, then run:

```sh
npx @deepseek-ai/dsh web
```

The command starts the Web UI at `http://127.0.0.1:3080` by default and opens it in the default browser for a local launch. An SSH launch only prints the host URL because the SSH client or editor owns the local forwarded address. Pass `--no-open` to run the server without opening a browser. See [Web UI guide](docs/user/guide/index.md).

### Run from source

To run from a repository checkout:

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh web
```

`pnpm run build` prepares the repository artifacts. `pnpm dsh web` uses those built artifacts without rebuilding.

## iOS (jailbroken)

A community port of `dsh` runs on jailbroken iOS (arm64, rootless jailbreaks such as Dopamine). It bundles a cross-compiled Node.js 22 runtime, a native `node-pty` addon, and JS shims for `sharp`/`require-builtin`, packaged as a `.deb`.

- Build & packaging guide: [docs/ios-port.md](docs/ios-port.md)
- Current package: `dsh-ios_0.1.1-rc.2-1_iphoneos-arm64.deb`

Known limitations: `sharp`/`libvips` are shimmed (no image processing); `node-pty` is built but pending on-device verification; on a device (SSH/terminal context) the runtime must run `--jitless` (V8 cannot obtain executable memory), which disables WebAssembly — the bundled `fetch-shim.cjs` (node:http based) restores `fetch`, and the runtime ships with ICU so Unicode property regexes work. See [docs/ios-port.md](docs/ios-port.md) for the full runtime constraints.

## Community and support

- Feel free to submit feedback or bug reports through [GitHub Discussions](https://github.com/deepseek-ai/deepseek-harness/discussions).
- Add the [`dsh-plugin`](https://github.com/topics/dsh-plugin) topic to your plugin repository for discoverability.
- Join <a href="https://discord.gg/Ycq5dCaS4">DeepSeek Harness Discord community</a>.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Development

Start with the [development guide](docs/development.md) and [architecture documentation](docs/architecture.md).

For agents, follow [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE)

Third-party dependencies and their licenses are disclosed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

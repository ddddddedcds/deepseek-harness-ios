#!/bin/sh
# build-node-ios.sh — cross-compile Node.js 22.23.2 for jailbroken iOS (arm64)
# and package the nodejs .deb (rootless /var/jb layout, darwin-style JIT path).
#
# Usage: ./scripts/build-node-ios.sh
# Output: dist/nodejs_22.23.2-1_iphoneos-arm64.deb
set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mkdir -p dist

NODE_VER=22.23.2
NODE_SRC="$ROOT/node-v$NODE_VER"
SHIM="$ROOT/ios-sdk-shim"

echo "== [0/6] 缓存命中检测 =="
if [ -f "$NODE_SRC/out/Release/node" ]; then
  echo "构建产物已缓存，增量编译..."
  cd "$NODE_SRC"
  SDK=$(xcrun --sdk iphoneos --show-sdk-path)
  export CC="/usr/bin/clang -target arm64-apple-ios16.0 -isysroot $SDK -miphoneos-version-min=16.0 -I$SHIM"
  export CXX="/usr/bin/clang++ -target arm64-apple-ios16.0 -isysroot $SDK -miphoneos-version-min=16.0 -stdlib=libc++ -std=gnu++20 -I$SHIM"
  export CC_host=/usr/bin/clang
  export CXX_host="/usr/bin/clang++ -std=gnu++20"
  ninja -C out/Release node
  echo "增量编译完成"
else
  echo "无缓存，走完整构建"
fi

echo "== [1/6] Node $NODE_VER 源码 =="
if [ ! -d "$NODE_SRC" ]; then
  curl -sL -o /tmp/node-src.tar.gz "https://nodejs.org/dist/v$NODE_VER/node-v$NODE_VER.tar.gz"
  tar xzf /tmp/node-src.tar.gz -C "$ROOT"
fi

echo "== [2/6] 应用 iOS 补丁 =="
python3 "$(dirname "$0")/apply_patches.py" "$NODE_SRC"

echo "== [3/6] configure（darwin JIT 路径 + ninja）=="
cd "$NODE_SRC"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
export CC="/usr/bin/clang -target arm64-apple-ios16.0 -isysroot $SDK -miphoneos-version-min=16.0 -I$SHIM"
export CXX="/usr/bin/clang++ -target arm64-apple-ios16.0 -isysroot $SDK -miphoneos-version-min=16.0 -stdlib=libc++ -std=gnu++20 -I$SHIM"
export CC_host=/usr/bin/clang
export CXX_host="/usr/bin/clang++ -std=gnu++20"
./configure --dest-os=ios --dest-cpu=arm64 --with-intl=none --prefix=/var/jb/usr/local --openssl-no-asm --ninja

echo "== [4/6] ninja host 生成器去冲突（configure 后必做）=="
cd out/Release
node -e '
const fs = require("fs");
function patch(f) {
  const hostP = "obj.host/tools/v8_gypfiles/" + f;
  const targetP = "obj/tools/v8_gypfiles/" + f;
  if (!fs.existsSync(targetP)) return;
  const lines = fs.readFileSync(hostP, "utf8").split("\n");
  const stmts = []; let cur = null;
  for (const l of lines) { if (/^\S/.test(l)) { cur = [l]; stmts.push(cur); } else if (cur && l.trim()) cur.push(l); }
  const joined = (s) => s.map(l => l.trimEnd().replace(/\$$/, "")).join(" ").replace(/\s+/g, " ").trim();
  const out = []; let dropped = 0;
  for (const s of stmts) {
    const j = joined(s);
    if (j.startsWith("rule ")) { dropped++; continue; }
    if (j.startsWith("build ")) {
      const c = j.indexOf(":");
      const o = (c >= 0 ? j.slice(6, c) : "").trim();
      if (/^gen\//.test(o)) { dropped++; continue; }
    }
    out.push(...s);
  }
  if (dropped) { fs.writeFileSync(hostP, out.join("\n") + "\n"); console.log("  patched:", f, "删除:", dropped); }
}
for (const f of fs.readdirSync("obj.host/tools/v8_gypfiles")) { if (f.endsWith(".ninja")) patch(f); }
'

echo "== [5/6] ninja 构建 =="
cd "$NODE_SRC"
ninja -C out/Release node

echo "== [6/6] 打包 nodejs deb =="
rm -rf /tmp/node-ios-staging /tmp/nodejs-deb
make install DESTDIR=/tmp/node-ios-staging >/dev/null
rm -rf /tmp/node-ios-staging/var/jb/usr/local/include /tmp/node-ios-staging/var/jb/usr/local/share/man
mkdir -p /tmp/nodejs-deb/DEBIAN /tmp/nodejs-deb/var/jb/usr/local/lib/nodejs
cp -a /tmp/node-ios-staging/var/jb/usr/local/. /tmp/nodejs-deb/var/jb/usr/local/
cp "$(dirname "$0")/node-jit-entitlements.plist" /tmp/nodejs-deb/var/jb/usr/local/lib/nodejs/entitlements.plist
cat > /tmp/nodejs-deb/DEBIAN/control <<'CTRL'
Package: nodejs
Name: Node.js (iOS arm64)
Version: 22.23.2-1
Architecture: iphoneos-arm64
Maintainer: dsh-ios port
Section: Development
Description: Node.js 22.23.2 cross-compiled for jailbroken iOS (rootless /var/jb layout). Darwin-style V8 JIT path (no MAP_JIT) for full JIT+WASM. Bundles npm, npx, corepack.
CTRL
cat > /tmp/nodejs-deb/DEBIAN/postinst <<'CTRL'
#!/bin/sh
P=/var/jb/usr/local
if command -v ldid >/dev/null 2>&1; then
  ldid -S"$P/lib/nodejs/entitlements.plist" "$P/bin/node" 2>/dev/null && echo "node signed (JIT entitlements)" || echo "WARN: node signing failed"
else
  echo "WARN: ldid not found"
fi
exit 0
CTRL
chmod 755 /tmp/nodejs-deb/DEBIAN/postinst
dpkg-deb -b --root-owner-group -Zgzip /tmp/nodejs-deb "$ROOT/dist/nodejs_22.23.2-1_iphoneos-arm64.deb" >/dev/null
echo "✅ $ROOT/dist/nodejs_22.23.2-1_iphoneos-arm64.deb"

#!/bin/bash
# 下载 RIME 输入法引擎（iOS 静态库），校验 SHA-256 后解压到 ios/Vendor/。
# 来源：ghostflyby/librime-xcframework，用 GitHub Actions 从上游 rime/librime 1.17.0 源码编译（Xcode 16.4）。
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="1.17.0-pack.10.0.0"
SHA="9e9923112ee9cee9bb53c25b41e51a2d7ea2ab3d91f34c7c99682224a23718ac"
URL="https://github.com/ghostflyby/librime-xcframework/releases/download/$TAG/librime-static.xcframework.zip"
mkdir -p Vendor
if [ -d Vendor/librime-static.xcframework ]; then echo "已存在 Vendor/librime-static.xcframework"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/rime.zip"
echo "$SHA  $TMP/rime.zip" | shasum -a 256 -c -
unzip -q "$TMP/rime.zip" -d Vendor
echo "已解压到 Vendor/librime-static.xcframework"

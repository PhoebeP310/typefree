#!/bin/bash
# 本地改动：自编译版一键 编译 → 用固定自签证书重签 → 安装到 /Applications → 启动。
# 用固定证书签名后，designated requirement 绑定证书而不是 cdhash，
# 重新编译后麦克风 / 辅助功能等系统权限不会失效。
# 证书一次性生成，见 ~/.config/typefree-signing/（不在仓库里）。
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="Typefree Local Signing"
DERIVED="$MAC_DIR/.derived"
BUILT_APP="$DERIVED/Build/Products/Release/Typefree.app"
TARGET_APP="/Applications/Typefree.app"
ENTITLEMENTS="$MAC_DIR/Resources/VoicePolish.entitlements"
LOG="$DERIVED/local_install_build.log"

# 证书未受信任时 find-identity -v 会过滤掉，所以不加 -v；能签就行
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "错误：钥匙串里找不到签名证书「$IDENTITY」。" >&2
  echo "请先按步骤 2 生成自签证书并导入登录钥匙串（私钥材料放在 ~/.config/typefree-signing/）。" >&2
  exit 1
fi

echo "==> 编译（Release / arm64），日志：$LOG"
mkdir -p "$DERIVED"
cd "$MAC_DIR"
if ! xcodebuild -project VoicePolish.xcodeproj -scheme VoicePolish -configuration Release \
    -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
    build >"$LOG" 2>&1; then
  tail -30 "$LOG" >&2
  echo "错误：编译失败，完整日志见 $LOG" >&2
  exit 1
fi
[ -d "$BUILT_APP" ] || { echo "错误：找不到编译产物 $BUILT_APP" >&2; exit 1; }

echo "==> 用「$IDENTITY」重签"
# 由内到外：先签内嵌 framework（含 Sparkle 的 XPC / Updater.app），再签主 App
if [ -d "$BUILT_APP/Contents/Frameworks" ]; then
  for fw in "$BUILT_APP/Contents/Frameworks/"*; do
    [ -e "$fw" ] || continue
    codesign --force --deep --sign "$IDENTITY" "$fw"
  done
fi
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP"
DR="$(codesign -d -r- "$BUILT_APP" 2>&1 | grep '^designated' || true)"
if [[ "$DR" != *"certificate leaf"* ]]; then
  echo "错误：签名要求没有绑定证书：$DR" >&2
  exit 1
fi

echo "==> 安装到 $TARGET_APP"
osascript -e 'quit app "Typefree"' >/dev/null 2>&1 || true
sleep 2
# 不先删旧 App：直接 ditto 覆盖，保留目录本身
ditto "$BUILT_APP" "$TARGET_APP"
xattr -cr "$TARGET_APP"
open "$TARGET_APP"

VERSION="$(defaults read "$TARGET_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
echo
echo "完成："
echo "  版本：$VERSION"
echo "  签名：$IDENTITY"
echo "  $(codesign -d -r- "$TARGET_APP" 2>&1 | grep '^designated')"

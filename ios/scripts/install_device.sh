#!/bin/bash
# 编译并装到用 USB 连着的 iPhone。免费 Apple ID 签名 7 天过期，过期后重跑一次即可（设置和词库不会丢）。
# 用法：bash ios/scripts/install_device.sh [--import]   可选环境变量 TYPEFREE_TEAM_ID
#   --import：装完顺便用数据线把 Mac 的 Key / 热词 / 润色规则推到 iPhone，下次打开 Typefree 自动导入（不需要通用剪贴板）
set -euo pipefail

cd "$(dirname "$0")/.."
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# 1. 团队 ID：优先用环境变量，否则从 Xcode 登录的账号里找个人团队
TEAM_ID="${TYPEFREE_TEAM_ID:-}"
if [ -z "$TEAM_ID" ]; then
  defaults export com.apple.dt.Xcode "$SCRATCH/xcode.plist"
  TEAM_ID="$(/usr/bin/python3 -I - "$SCRATCH/xcode.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
teams = [t for ts in d.get("IDEProvisioningTeamByIdentifier", {}).values() for t in ts]
teams.sort(key=lambda t: not t.get("isFreeProvisioningTeam", False))
print(teams[0]["teamID"] if teams else "")
PY
)"
fi
if [ -z "$TEAM_ID" ]; then
  echo "找不到开发团队：打开 Xcode → Settings → Accounts，选中你的 Apple ID，确认右侧出现「(Personal Team)」后再跑。" >&2
  exit 1
fi
echo "团队：$TEAM_ID"

# 2. 找连着的 iPhone
xcrun devicectl list devices --json-output "$SCRATCH/devices.json" >/dev/null
read -r UDID DEVICE_NAME OS_VERSION < <(/usr/bin/python3 -I - "$SCRATCH/devices.json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hw, props = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
    if hw.get("platform") == "iOS" and hw.get("udid"):
        print(hw["udid"], props.get("name", "iPhone").replace(" ", "_"), props.get("osVersionNumber", "?"))
        break
PY
) || true
if [ -z "${UDID:-}" ]; then
  echo "没找到 iPhone：用数据线连上 Mac，解锁手机，弹窗里点「信任」。" >&2
  exit 1
fi
echo "设备：$DEVICE_NAME（iOS $OS_VERSION）"

# 3. 生成工程并编译签名
TYPEFREE_TEAM_ID="$TEAM_ID" xcodegen generate --quiet
xcodebuild -project TypefreeiOS.xcodeproj -scheme Typefree -configuration Release \
  -destination "id=$UDID" -derivedDataPath .derived \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" build 2>&1 | grep -E "error:|warning: .*[Pp]rovision|BUILD (SUCCEEDED|FAILED)" || true

APP=".derived/Build/Products/Release-iphoneos/Typefree.app"
if [ ! -d "$APP" ]; then
  echo "编译失败，看上面的 error。" >&2
  exit 1
fi

# 4. 安装
xcrun devicectl device install app --device "$UDID" "$APP"

# 5. 推送设置（文件在 App 读完后自行删除；本地临时文件随 trap 删除）
if [ "${1:-}" = "--import" ]; then
  bash scripts/export_mac_config.sh --stdout > "$SCRATCH/typefree-import.json"
  xcrun devicectl device copy to --device "$UDID" \
    --domain-type appDataContainer --domain-identifier com.phoebep310.typefree \
    --source "$SCRATCH/typefree-import.json" --destination Documents/typefree-import.json
  echo "设置已推到手机，打开 Typefree 会自动导入。"
fi

cat <<'EOF'

装好了。第一次装还要在 iPhone 上做三件事：
  1. 设置 → 隐私与安全性 → 开发者模式 → 打开（会重启手机）
  2. 设置 → 通用 → VPN 与设备管理 → 你的 Apple ID → 信任
  3. 打开 Typefree，按页面提示添加键盘、导入 Mac 设置
EOF

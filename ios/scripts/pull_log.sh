#!/bin/bash
# 经数据线把 iPhone 上 Typefree 的排障日志拉到 Mac（只有状态和报错，不含识别文字）。
# 用法：bash ios/scripts/pull_log.sh [输出路径]，默认打印最后 60 行
set -euo pipefail
OUT="${1:-$(mktemp -d)/typefree-debug.log}"
UDID="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && (/available/ || /connected/) {print $3; exit}')"
[ -n "$UDID" ] || { echo "没找到 iPhone，请用数据线连上并解锁" >&2; exit 1; }
xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier com.phoebep310.typefree \
  --source Documents/typefree-debug.log --destination "$OUT" >/dev/null
tail -60 "$OUT"

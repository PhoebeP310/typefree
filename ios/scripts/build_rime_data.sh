#!/bin/bash
# 生成键盘用的小鹤双拼数据（方案 + 预编译词库）到 Keyboard/RimeData/。
# 词库：雾凇拼音（iDvel/rime-ice，GPL-3.0）的 8105 字表 + base 基础词库 + others，拼写规则取自它的 double_pinyin_flypy。
# 依赖：brew install librime（提供 rime_deployer）
set -euo pipefail
cd "$(dirname "$0")/.."
COMMIT="${RIME_ICE_COMMIT:-da1fbe6}"
OUT="Keyboard/RimeData"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone -q https://github.com/iDvel/rime-ice.git "$TMP/rime-ice"
git -C "$TMP/rime-ice" checkout -q "$COMMIT"
mkdir -p "$TMP/shared/cn_dicts" "$TMP/user"
cp "$TMP/rime-ice"/cn_dicts/{8105,base,others}.dict.yaml "$TMP/shared/cn_dicts/"
cp "$TMP/rime-ice/LICENSE" "$TMP/shared/rime-ice-LICENSE"
/usr/bin/python3 -I "$(dirname "$0")/make_rime_schema.py" "$TMP/rime-ice/double_pinyin_flypy.schema.yaml" "$TMP/shared"
rime_deployer --build "$TMP/user" "$TMP/shared" "$TMP/shared/build" >/dev/null 2>&1
test -f "$TMP/shared/build/typefree.table.bin" || { echo "词库编译失败" >&2; exit 1; }
mkdir -p "$OUT/build"
cp "$TMP/shared"/{default.yaml,typefree_flypy.schema.yaml,typefree.dict.yaml,rime-ice-LICENSE} "$OUT/"
cp "$TMP/shared/build"/{default.yaml,typefree.table.bin,typefree.reverse.bin,typefree_flypy.prism.bin,typefree_flypy.schema.yaml} "$OUT/build/"
du -sh "$OUT"

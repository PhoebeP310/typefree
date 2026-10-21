#!/bin/bash
# 把 Mac 版 Typefree 的识别 / 润色设置（含 Key）复制到剪贴板，通过通用剪贴板粘到 iPhone 版。
# iPhone 上点「从剪贴板导入 Mac 设置」后会自动清空剪贴板。
# 加 --stdout 改为输出到标准输出（install_device.sh --import 用数据线推送时用）。
set -euo pipefail
# 没设 UTF-8 时 pbcopy 会把含中文的内容整段丢掉
export LC_CTYPE=UTF-8

CONFIG_DIR="${HOME}/.config/voicepolish"

TO_STDOUT=0
[ "${1:-}" = "--stdout" ] && TO_STDOUT=1

emit() { if [ "$TO_STDOUT" = 1 ]; then cat; else pbcopy; fi; }

/usr/bin/python3 -I - "$CONFIG_DIR" <<'PY' | emit
import json, os, sys

config_dir = sys.argv[1]

def load(name):
    path = os.path.join(config_dir, name)
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)

config = load("config.json")
secrets = load("secrets.json")

config_keys = {
    "bigasr_version", "bigasr_include_builtin_hot_words", "bigasr_app_id",
    "bigasr_boosting_table_name", "bigasr_boosting_table_id",
    "bigasr_correct_table_name", "bigasr_correct_table_id",
    "hot_words", "hot_words_groups", "term_corrections",
    "polish_provider", "polish_user_rules",
    "qwen_polish_model", "deepseek_polish_model", "doubao_polish_model", "zhipu_polish_model",
    "output_languages", "default_output_language", "output_language_command_enabled",
}
secret_keys = {
    "ark_api_key", "dashscope_api_key", "bigasr_api_key",
    "bigasr_access_token", "zhipu_api_key", "deepseek_api_key",
}

payload = {
    "typefree_export": 1,
    "config": {k: v for k, v in config.items() if k in config_keys},
    "secrets": {k: v for k, v in secrets.items() if k in secret_keys and v},
}
# 老版本的明文 Key 可能还在 config.json 里
for k in secret_keys:
    if k not in payload["secrets"] and config.get(k):
        payload["secrets"][k] = config[k]

print(json.dumps(payload, ensure_ascii=False))
sys.stderr.write("已导出：%d 项设置、%d 个 Key（%s）、热词 %d 个\n" % (
    len(payload["config"]), len(payload["secrets"]), "、".join(sorted(payload["secrets"])),
    len(payload["config"].get("hot_words", []))))
PY

[ "$TO_STDOUT" = 1 ] && exit 0
echo "在 iPhone 的 Typefree 里点「从剪贴板导入 Mac 设置」（Mac 和 iPhone 需登录同一 Apple ID 并打开接力）。"

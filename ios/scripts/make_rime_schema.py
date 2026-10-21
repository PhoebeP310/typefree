"""从雾凇拼音的 double_pinyin_flypy.schema.yaml 抽出小鹤拼写规则，生成精简方案 typefree_flypy（不用 lua / 英文 / 拆字）。"""
import sys

src, out = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().split("\n")


def block(start, indent):
    result, inside = [], False
    for line in lines:
        if not inside:
            if line.startswith(start):
                inside = True
                result.append(line)
            continue
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if len(line) - len(line.lstrip()) < indent:
            break
        result.append(line)
    return result


speller = "\n".join(block("speller:", 2))
preedit = "\n".join(block("  preedit_format:", 4)[1:])
schema = f"""# Typefree 精简版小鹤双拼：拼写规则取自雾凇拼音 double_pinyin_flypy，去掉 lua / 英文 / 拆字等扩展
schema:
  schema_id: typefree_flypy
  name: 小鹤双拼
  version: "1"

engine:
  processors:
    - speller
    - selector
    - navigator
    - express_editor
  segmentors:
    - abc_segmentor
    - fallback_segmentor
  translators:
    - script_translator
  filters:
    - uniquifier

{speller}

translator:
  dictionary: typefree
  prism: typefree_flypy
  enable_word_completion: true
  preedit_format:
{preedit}
"""
open(f"{out}/typefree_flypy.schema.yaml", "w", encoding="utf-8").write(schema)
open(f"{out}/typefree.dict.yaml", "w", encoding="utf-8").write(
    "# Typefree：雾凇拼音的字表 + 基础词库（不含扩展词库和腾讯词库，控制体积）\n---\nname: typefree\nversion: \"1\"\n"
    "import_tables:\n  - cn_dicts/8105\n  - cn_dicts/base\n  - cn_dicts/others\n...\n")
open(f"{out}/default.yaml", "w", encoding="utf-8").write("schema_list:\n  - schema: typefree_flypy\nmenu:\n  page_size: 9\n")

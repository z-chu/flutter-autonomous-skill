#!/usr/bin/env bash
# tap-by-label.sh — 按 label 子串一步点中心(弥补 mobilecli/mobile-mcp 只有坐标级 io tap、
# 没有"按 label 一步点"原生命令的缺口)。零依赖,只用 mobilecli + jq。
#
# 用法:
#   tap-by-label.sh <deviceId> <labelSubstring> [--index N] [--dump-only]
#
# 参数:
#   <deviceId>        mobilecli devices 里的设备 id(脚本不写死设备,运行期传入)
#   <labelSubstring>  要匹配的子串;对每个节点的 label / text / name 任一做"包含"(不区分大小写)
#   --index N         多个匹配时点第 N 个(0 起;默认 0)
#   --dump-only       只列出所有匹配(label + 中心坐标),不点 —— 先检视再决定点谁
#
# 逻辑:
#   1) mobilecli dump ui --device "$D" --format json 拿 ScreenElement 树
#      节点结构:{type,label?,text?,name?,value?,placeholder?,identifier?,
#                rect:{x,y,width,height 整数物理像素},children:[]}
#   2) jq 递归 recurse(.children[]?),匹配 label/text/name 任一含子串(忽略大小写),
#      算中心 (rect.x + rect.width/2, rect.y + rect.height/2)
#   3) 匹配结果按 rect 面积**升序**排 —— Semantics 合并后祖先容器的 label 天然包含子串,
#      而 jq 的 `..` 是前序遍历(父先于子),不排序的话 [0] 常常是整行/整个 Card,
#      点下去落在容器空白处 = "点了没反应"。面积最小的那个才最可能是你要的叶子控件。
#   4) --dump-only 只列;否则点第 --index 个匹配:mobilecli io tap --device "$D" <cx>,<cy>
#
# 注意:输出的 TSV 把坐标放前、label 垫底并用 @tsv 转义 —— Flutter 的 Semantics 合并
#      经常产出**带换行的 label**(如 "SOL\n$123.45\n+2.3%"),label 在首列且不转义时
#      会把一行撑成多行,导致行数错乱、读到空坐标、点到 (0,0)。
#
# 退出码:0 成功;1 用法错;2 缺依赖(jq/mobilecli);3 dump 失败;4 无匹配;5 --index 越界

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
用法: tap-by-label.sh <deviceId> <labelSubstring> [--index N] [--dump-only]

  <deviceId>        mobilecli devices 里的设备 id
  <labelSubstring>  匹配子串,对 label/text/name 任一做"包含"(不区分大小写)
  --index N         多个匹配时点第 N 个(0 起;默认点第 0 个)
  --dump-only       只列出所有匹配(label + 中心坐标),不点

示例:
  tap-by-label.sh <deviceId> "提交"                 # 点第一个含"提交"的控件
  tap-by-label.sh <deviceId> "Buy" --dump-only      # 先看有哪些匹配
  tap-by-label.sh <deviceId> "Buy" --index 1        # 点第 2 个匹配
EOF
  exit 1
}

# ---- 解析参数 ----------------------------------------------------------------
DEVICE=""
NEEDLE=""
INDEX=0
DUMP_ONLY=0
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --index)
      [ $# -ge 2 ] || { echo "错误: --index 需要一个数值参数" >&2; usage; }
      INDEX="$2"; shift 2 ;;
    --index=*)
      INDEX="${1#*=}"; shift ;;
    --dump-only)
      DUMP_ONLY=1; shift ;;
    -h|--help)
      usage ;;
    --*)
      echo "错误: 未知选项 '$1'" >&2; usage ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done

# 位置参数:deviceId + labelSubstring(都必填)
[ "${#POSITIONAL[@]}" -ge 2 ] || { echo "错误: 缺少 <deviceId> 或 <labelSubstring>" >&2; usage; }
DEVICE="${POSITIONAL[0]}"
NEEDLE="${POSITIONAL[1]}"

# --index 必须是非负整数
case "$INDEX" in
  ''|*[!0-9]*) echo "错误: --index 需为非负整数,收到 '$INDEX'" >&2; usage ;;
esac

# ---- 依赖检查 ----------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "错误: 未找到 jq —— 本脚本靠 jq 解析 dump ui 的 JSON。" >&2
  echo "  macOS:  brew install jq" >&2
  echo "  Linux:  apt install jq   (或 yum/dnf/apk 对应包)" >&2
  exit 2
fi
if ! command -v mobilecli >/dev/null 2>&1; then
  echo "错误: 未找到 mobilecli —— 交互底座缺失。" >&2
  echo "  装: npm i -g mobilecli@latest   (或 npx mobilecli@latest)" >&2
  exit 2
fi

# ---- 抓 UI 树 ----------------------------------------------------------------
# dump ui --format json:整棵 ScreenElement 树,rect 为整数物理像素
UI_JSON="$(mobilecli dump ui --device "$DEVICE" --format json 2>/dev/null)" || {
  echo "错误: mobilecli dump ui 失败 —— 设备 '$DEVICE' 是否在线/前台是否为目标 App?" >&2
  echo "  自查: mobilecli devices   /   mobilecli apps foreground --device '$DEVICE'" >&2
  exit 3
}
if [ -z "$UI_JSON" ]; then
  echo "错误: dump ui 返回空 —— 设备 '$DEVICE' 可能离线或无前台 App。" >&2
  exit 3
fi

# ---- 递归匹配 + 算中心 -------------------------------------------------------
# 输出每个匹配一行 TSV: <cx>\t<cy>\t<area>\t<label>
#   坐标在前、label 垫底:label 里的换行/制表符不会再撑乱行结构(再叠 @tsv 转义 + 折叠空白)
#   label 取 label / text / name 第一个非空者(纯展示用)
#   匹配规则:label/text/name 任一(转小写)包含 needle(转小写)
#   中心: x + width/2, y + height/2(整数取整,贴近 mobilecli io tap 的像素语义)
#   排序: 按 rect 面积升序 —— 最小的最可能是叶子控件,而非包含它的行/卡片容器
MATCHES="$(printf '%s' "$UI_JSON" | jq -r --arg needle "$NEEDLE" '
  ($needle | ascii_downcase) as $q
  | [ .. | objects | select(has("rect"))
      | . as $n
      | ( [ ($n.label // ""), ($n.text // ""), ($n.name // "") ]
          | map(ascii_downcase) ) as $hay
      | select( any($hay[]; contains($q)) )
      | {
          label: ( ($n.label // $n.text // $n.name // "(无 label)")
                   | tostring | gsub("\\s+"; " ") ),
          cx:   ( ($n.rect.x + ($n.rect.width  / 2)) | floor ),
          cy:   ( ($n.rect.y + ($n.rect.height / 2)) | floor ),
          area: ( ((($n.rect.width // 0) * ($n.rect.height // 0))) | floor )
        }
    ]
  | sort_by(.area)
  | .[]
  | [ .cx, .cy, .area, .label ] | @tsv
')" || {
  echo "错误: jq 解析 dump ui 输出失败(JSON 结构异常?)" >&2
  exit 3
}

# 无匹配 —— 给出最可能的根因(没暴露 Semantics / 纯 canvas),引导回代码补
if [ -z "$MATCHES" ]; then
  echo "未找到含 '$NEEDLE' 的元素。" >&2
  echo "可能原因:" >&2
  echo "  1) 该控件没暴露 Semantics —— 自定义手势控件(Touchable/GestureDetector/InkWell)" >&2
  echo "     默认 dump 不出,需显式包 Semantics(label: ..., button: true)。" >&2
  echo "  2) 纯 canvas 绘制(图表内部等),无 Semantics 包裹 —— 回代码补 Semantics(label:)," >&2
  echo "     或对这种节点退回截图量坐标盲点(末选)。" >&2
  echo "  3) 子串拼写/大小写无关但内容不符 —— 先全量检视:" >&2
  echo "       mobilecli dump ui --device '$DEVICE' --format json | jq -r '.. | objects | select(has(\"rect\")) | .label // .text // .name // empty'" >&2
  exit 4
fi

# 统计匹配数
COUNT="$(printf '%s\n' "$MATCHES" | wc -l | tr -d ' ')"

# ---- --dump-only: 只列不点 ---------------------------------------------------
if [ "$DUMP_ONLY" -eq 1 ]; then
  echo "含 '$NEEDLE' 的匹配($COUNT 个,按面积升序,索引 0 起):"
  i=0
  while IFS=$'\t' read -r cx cy area label; do
    printf '  [%d] %-40s 中心=(%s,%s) 面积=%s\n' "$i" "$label" "$cx" "$cy" "$area"
    i=$((i + 1))
  done <<< "$MATCHES"
  echo "提示: 面积大的多半是包住目标的行/卡片容器,点它会落在空白处;用 --index N 点指定项(默认点 [0]=最小的那个)。" >&2
  exit 0
fi

# ---- 选中目标 + 越界检查 -----------------------------------------------------
if [ "$INDEX" -ge "$COUNT" ]; then
  echo "错误: --index $INDEX 越界 —— 含 '$NEEDLE' 的匹配只有 $COUNT 个(有效索引 0..$((COUNT - 1)))。" >&2
  echo "  先看全部: tap-by-label.sh '$DEVICE' '$NEEDLE' --dump-only" >&2
  exit 5
fi

# 多匹配且未显式指定 index —— 提示用 --index 精确选,本次默认点 [0](面积最小者)
if [ "$COUNT" -gt 1 ] && [ "$INDEX" -eq 0 ]; then
  echo "警告: 含 '$NEEDLE' 的匹配有 $COUNT 个,本次默认点面积最小的第 [0] 个;若不对请用 --index N 精确选(--dump-only 先看全部)。" >&2
fi

# 取第 INDEX 行(sed 行号 1 起,故 +1)
TARGET_LINE="$(printf '%s\n' "$MATCHES" | sed -n "$((INDEX + 1))p")"
IFS=$'\t' read -r CX CY AREA LABEL <<< "$TARGET_LINE"

# 坐标兜底校验:任何一步把行结构搞乱都会在这里被拦下,而不是静默点到 (0,0)
for v in "${CX:-}" "${CY:-}"; do
  case "$v" in
    ''|*[!0-9]*) echo "错误: 解析到的坐标非法(cx='${CX:-}' cy='${CY:-}',原始行: $TARGET_LINE)。" >&2; exit 3 ;;
  esac
done

# ---- 点击 + 取证回显 ---------------------------------------------------------
mobilecli io tap --device "$DEVICE" "$CX,$CY" >/dev/null || {
  echo "错误: mobilecli io tap 失败(设备 '$DEVICE',坐标 $CX,$CY)。" >&2
  exit 3
}
echo "已点击 [索引 $INDEX] label='$LABEL' 坐标=($CX,$CY) 面积=$AREA 设备='$DEVICE'"

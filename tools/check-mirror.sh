#!/usr/bin/env bash
# check-mirror.sh — 守住 zh → en/ 镜像不再悄悄落后（维护者工具，不随 skill 分发）
#
# 背景：README 说「中文是 source of truth，en/ 随后同步」。这是靠自觉的约定，
# 而它已经失效过——en/ 曾整整落后一个版本（缺 §0、缺 VM Service 整条路、
# description 还在宣传被删掉的用法）。英文用户拿到的是被否定过的行为，
# 而仓库看不出任何异常。这个脚本把那次事故变成一条能自动发现的检查。
#
# 用法：
#   bash tools/check-mirror.sh              # 结构体检：文件是否成对、标题/代码块数是否对得上
#   bash tools/check-mirror.sh --diff main  # 改动体检：本分支改了 zh 却没改对应 en，直接报错
#
# 退出码：0 = 通过；1 = 发现问题（可直接用在 CI / pre-push hook 里）
#
# 刻意不做的事：不比对措辞、不算翻译质量——那是人的判断。它只回答一个问题：
# 「这次改动有没有可能只落在一边？」漏报好过误报到没人愿意跑它。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/flutter-autonomous"
EN="$SKILL/en"
FAIL=0

c_red=$'\033[31m'; c_yel=$'\033[33m'; c_grn=$'\033[32m'; c_dim=$'\033[2m'; c_0=$'\033[0m'
err()  { printf '%s✗%s %s\n' "$c_red" "$c_0" "$*"; FAIL=1; }
warn() { printf '%s!%s %s\n' "$c_yel" "$c_0" "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_grn" "$c_0" "$*"; }

# 需要成对存在的 zh 文件（相对 $SKILL）。scripts/ 是代码、不翻译，故不在列。
mirrored_files() {
  (cd "$SKILL" && find . -name '*.md' -not -path './en/*' | sed 's|^\./||' | sort)
  (cd "$SKILL" && find templates -type f -name '*.json' 2>/dev/null | sort)
}

# 必须跳过代码块内部：shell 注释 `# foo` 长得和 h1 一模一样，直接 grep 会把
# 命令示例里的注释数进标题里，两边注释风格稍有差异就误报——误报会让人不再跑这个脚本。
count_headings() {
  awk '/^```/ { inb = !inb; next } !inb && /^#{1,6} / { n++ } END { print n+0 }' "$1"
}
count_fences() { grep -c '^```' "$1" 2>/dev/null; true; }

structure_check() {
  echo "结构体检：$SKILL → en/"
  echo
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    zh="$SKILL/${rel}"; en="$EN/${rel}"
    if [ ! -f "$en" ]; then
      err "缺英文镜像：en/${rel}"
      continue
    fi
    zh_h=$(count_headings "$zh"); en_h=$(count_headings "$en")
    zh_f=$(count_fences   "$zh"); en_f=$(count_fences   "$en")
    if [ "$zh_h" -ne "$en_h" ]; then
      err "${rel}：标题数 zh=$zh_h en=$en_h ${c_dim}(多半是某一节没同步过去)${c_0}"
    elif [ "$zh_f" -ne "$en_f" ]; then
      err "${rel}：代码块数 zh=$zh_f en=$en_f ${c_dim}(有命令示例只落在一边)${c_0}"
    else
      ok  "${rel} ${c_dim}(标题 $zh_h / 代码块 $((zh_f/2)))${c_0}"
    fi
  done < <(mirrored_files)

  # 反向：en/ 有而 zh 没有的孤儿文件
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    [ -f "$SKILL/${rel}" ] || warn "en/${rel} 在中文侧没有对应文件（改名后忘了删？）"
  done < <(cd "$EN" 2>/dev/null && find . -name '*.md' | sed 's|^\./||' | sort)
}

diff_check() {
  local base="$1"
  git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1 || {
    err "基线 '$base' 不是有效的 git ref"; return
  }
  echo "改动体检：与 $base 相比"
  echo
  # 两点 diff（不是 base...HEAD）：把【工作区未提交的改动】也算进来——
  # 维护者最该跑这个脚本的时刻正是「刚改完、还没提交」，三点范围恰好看不见那些改动。
  local changed
  changed=$(git -C "$ROOT" diff --name-only "$base" -- skills/flutter-autonomous 2>/dev/null)
  # 新建但还没 git add 的文件不在 diff 里，补上
  changed=$(printf '%s\n%s\n' "$changed" \
    "$(git -C "$ROOT" ls-files --others --exclude-standard -- skills/flutter-autonomous)" | sed '/^$/d' | sort -u)
  [ -n "$changed" ] || { ok "没有改动，跳过"; return; }

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      *.md) ;;
      *) continue ;;                                # 只管翻译文件
    esac
    case "$path" in
      skills/flutter-autonomous/en/*) continue ;;   # 只从 zh 侧发起检查
    esac
    rel="${path#skills/flutter-autonomous/}"
    counterpart="skills/flutter-autonomous/en/${rel}"
    # 删除也是一种改动:中文没了,英文必须一起没——否则会留下一个没人维护的孤儿英文档
    if [ ! -f "$ROOT/$path" ]; then
      if [ -f "$ROOT/$counterpart" ]; then
        err "删了 ${rel}，${c_dim}但${c_0} en/${rel} 还在 ${c_dim}→ 会留下没人维护的孤儿${c_0}"
      else
        ok  "${rel} 与 en/${rel} 一起删了"
      fi
      continue
    fi
    [ -f "$ROOT/$counterpart" ] || { err "改了 ${rel}，但它没有英文镜像"; continue; }
    if grep -qxF "$counterpart" <<<"$changed"; then
      ok  "${rel} 与 en/${rel} 一起改了"
    else
      err "改了 ${rel}，${c_dim}但${c_0} en/${rel} 没动 ${c_dim}→ 英文用户会拿到旧行为${c_0}"
    fi
  done <<<"$changed"
}

case "${1:-}" in
  --diff) diff_check "${2:-main}" ;;
  ""|--structure) structure_check ;;
  *) echo "用法: $0 [--structure | --diff <base-ref>]" >&2; exit 2 ;;
esac

echo
if [ "$FAIL" -eq 0 ]; then
  ok "镜像同步"
else
  printf '%s镜像不同步%s —— 中文是 source of truth，把差的那部分补进 en/ 再提交。\n' "$c_red" "$c_0"
fi
exit "$FAIL"

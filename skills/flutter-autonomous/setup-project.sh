#!/usr/bin/env bash
# flutter-autonomous skill —— 一键把 templates 装进任意 Flutter 项目
#
# 用法:
#   bash setup-project.sh [<project-root>]      # 缺省 = 当前目录
#
# 做什么(全部可逆、可重入、绝不无备份覆盖):
#   1) 校验目标是 Flutter 项目(有 pubspec.yaml)
#   2) 装 .claude/commands/*(已存在逐个 .bak 备份)+ settings.json(已存在则放旁边让你 jq 合并)
#   3) 打印"装了什么 / 还需你手动做什么"
#
# 只往 <project-root>/.claude/ 里写,不碰你的项目根:包名/两端 id/入口由 skill 运行期
# 自己探测,设备现取,没有任何需要你提前配置的值。
#
# 设计原则:set -u 防未定义变量;不开 set -e(我们要逐项报告而非首错即退);
#           macOS(BSD sed) 与 Linux(GNU sed) 兼容(就地替换一律走临时文件,不用 -i)。
set -u

# ── 颜色(无 TTY 时降级为空串,避免管道里出现转义码) ─────────────
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_B=''; C_0=''
fi
ok()   { printf '%s✓%s %s\n'  "$C_OK"   "$C_0" "$*"; }
warn() { printf '%s!%s %s\n'  "$C_WARN" "$C_0" "$*"; }
err()  { printf '%s✗%s %s\n'  "$C_ERR"  "$C_0" "$*" >&2; }
info() { printf '%s· %s%s\n'  "$C_DIM"  "$*" "$C_0"; }

# 收集"需你手动做"的事项,最后统一打印
MANUAL_TODOS=()
todo() { MANUAL_TODOS+=("$1"); }

# ── 1. 解析参数 + 校验是 Flutter 项目 ──────────────────────────────
ROOT_ARG="${1:-.}"
# 解析为绝对路径(目录须已存在)
if [ ! -d "$ROOT_ARG" ]; then
  err "目标目录不存在: $ROOT_ARG"
  exit 1
fi
ROOT="$(cd "$ROOT_ARG" && pwd)"

if [ ! -f "$ROOT/pubspec.yaml" ]; then
  err "不是 Flutter 项目:$ROOT 下没有 pubspec.yaml"
  err "用法: bash setup-project.sh <flutter-project-root>"
  exit 1
fi
ok "目标 Flutter 项目: $ROOT"

# ── 2. 定位 skill 包根(脚本自身所在目录) ─────────────────────────
# 兼容 source / 软链:优先 BASH_SOURCE
SELF="${BASH_SOURCE[0]:-$0}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
TPL_DIR="$SKILL_DIR/templates"
SCRIPTS_DIR="$SKILL_DIR/scripts"

if [ ! -d "$TPL_DIR" ]; then
  err "找不到模板目录: $TPL_DIR(install.sh 必须放在 skill 包根)"
  exit 1
fi
info "skill 包根: $SKILL_DIR"

# 时间戳后缀,给备份用
TS="$(date +%Y%m%d-%H%M%S)"

# ── 3. 装 .claude/(commands + settings.json) ──────────────────────
echo
printf '%s── .claude/(commands + settings.json)──%s\n' "$C_B" "$C_0"
DST_DOTCLAUDE="$ROOT/.claude"
DST_CMDS="$DST_DOTCLAUDE/commands"
mkdir -p "$DST_CMDS"

# 4a. 5 个 command(spec / verify / ship / debug / nightly)
TPL_CMDS="$TPL_DIR/.claude/commands"
CMD_NAMES="spec verify ship debug nightly"
if [ -d "$TPL_CMDS" ]; then
  for name in $CMD_NAMES; do
    src="$TPL_CMDS/$name.md"
    dst="$DST_CMDS/$name.md"
    if [ ! -f "$src" ]; then
      warn "command 模板缺失,跳过: $name.md(skill 包内未提供)"
      continue
    fi
    if [ -f "$dst" ]; then
      bak="$dst.bak.$TS"
      if cp "$dst" "$bak" && cp "$src" "$dst"; then
        warn "已存在 $name.md → 备份为 $(basename "$bak") 后覆盖"
      else
        err "更新失败: $name.md"
      fi
    else
      if cp "$src" "$dst"; then
        ok "装入 command: .claude/commands/$name.md"
      else
        err "拷贝失败: $name.md"
      fi
    fi
  done
else
  warn "模板里没有 .claude/commands/,跳过 5 个 command(skill 尚未提供命令模板)"
  todo "skill 包补齐 templates/.claude/commands/{spec,verify,ship,debug,nightly}.md 后重跑本脚本"
fi

# 4b. settings.json —— 绝不直接覆盖
TPL_SET="$TPL_DIR/.claude/settings.json"
DST_SET="$DST_DOTCLAUDE/settings.json"
if [ ! -f "$TPL_SET" ]; then
  warn "模板缺失,跳过 settings.json: $TPL_SET"
elif [ -f "$DST_SET" ]; then
  SIDE_SET="$DST_DOTCLAUDE/settings.flutter-autonomous.json"
  if cp "$TPL_SET" "$SIDE_SET"; then
    warn "已存在 .claude/settings.json,未覆盖;模板放到旁边: $SIDE_SET"
    todo "用 jq 把 $SIDE_SET 的 permissions.allow / permissions.deny / hooks 合并进现有 settings.json,例如:"
    todo "  jq -s '.[0].permissions.allow = ((.[0].permissions.allow // []) + (.[1].permissions.allow // []) | unique) | .[0].hooks = (.[0].hooks // .[1].hooks) | .[0]' .claude/settings.json $(basename "$SIDE_SET") > .claude/settings.merged.json && mv .claude/settings.merged.json .claude/settings.json"
  else
    err "拷贝失败: $TPL_SET → $SIDE_SET"
  fi
else
  if cp "$TPL_SET" "$DST_SET"; then
    ok "新建 .claude/settings.json(权限白名单 + format/analyze hook)"
  else
    err "拷贝失败: $TPL_SET → $DST_SET"
  fi
fi

# ── 收尾:装了什么 / 还需手动做什么 / 下一步 ──────────────────────
echo
printf '%s═══ 安装完成 ═══%s\n' "$C_B" "$C_0"
echo
if [ "${#MANUAL_TODOS[@]}" -gt 0 ]; then
  printf '%s需你手动处理:%s\n' "$C_WARN" "$C_0"
  for t in "${MANUAL_TODOS[@]}"; do
    printf '  %s- %s%s\n' "$C_WARN" "$t" "$C_0"
  done
  echo
fi

printf '%s下一步:%s\n' "$C_B" "$C_0"
printf '  1) 环境自举(装 mobilecli / patrol / 体检):%sbash %s/scripts/bootstrap.sh%s\n' "$C_DIM" "$SKILL_DIR" "$C_0"
printf '  2) 在项目里跑 %s/ship%s 走「实现→上设备验证→修复→提交」闭环\n' "$C_DIM" "$C_0"
echo
printf '%s无需任何配置即可开跑%s:包名/两端 id/入口 AI 自己探,设备运行期现取。\n' "$C_DIM" "$C_0"
printf '%s只有跑无人值守(/nightly、/schedule)时才建议在你自己的 CLAUDE.md 里写清:项目特有红线、红线授权例外、提交策略%s\n' "$C_DIM" "$C_0"
printf '%s——那时没人可问,AI 只按写下来的办(未授权的红线一律跳过)。%s\n' "$C_DIM" "$C_0"
echo

exit 0

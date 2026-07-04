#!/usr/bin/env bash
# flutter-autonomous skill —— 一键把 templates 装进任意 Flutter 项目
#
# 用法:
#   bash setup-project.sh [<project-root>]      # 缺省 = 当前目录
#
# 做什么(全部可逆、可重入、绝不无备份覆盖):
#   1) 校验目标是 Flutter 项目(有 pubspec.yaml)
#   2) 装项目宪法 CLAUDE.md(已存在则放旁边 *.flutter-autonomous.md 让你手动合并)
#   3) 装 .claude/commands/*(已存在逐个 .bak 备份)+ settings.json(已存在则放旁边让你 jq 合并)
#   4) 自动探测 applicationId / bundleId / Dart 包名,sed 回填新建 CLAUDE.md 的占位
#   5) 打印"装了什么 / 还需你手动做什么"
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

# ── 工具函数:就地替换占位(BSD/GNU sed 通吃,走临时文件) ──────────
# 用法: sed_replace <file> <占位token如{{ANDROID_APPLICATION_ID}}> <替换值>
# 替换值里的 sed 元字符(& / \)做转义,避免值含特殊符号时炸掉
sed_replace() {
  _f="$1"; _token="$2"; _val="$3"
  [ -f "$_f" ] || return 0
  # 转义替换串中的 & 和 / 和 \
  _esc=$(printf '%s' "$_val" | sed -e 's/[&/\]/\\&/g')
  _tmp="$_f.tmp.$$"
  if sed "s/$_token/$_esc/g" "$_f" > "$_tmp" 2>/dev/null; then
    mv "$_tmp" "$_f"
  else
    rm -f "$_tmp"
  fi
}

# ── 3. 装项目宪法 CLAUDE.md ────────────────────────────────────────
echo
printf '%s── CLAUDE.md(项目宪法)──%s\n' "$C_B" "$C_0"
TPL_CLAUDE="$TPL_DIR/CLAUDE.md"
DST_CLAUDE="$ROOT/CLAUDE.md"
# 记录这次"新建/可回填"的 CLAUDE 路径(只对新建的做 sed,绝不动用户已有 CLAUDE.md)
FILLABLE_CLAUDE=""

if [ ! -f "$TPL_CLAUDE" ]; then
  warn "模板缺失,跳过 CLAUDE.md: $TPL_CLAUDE"
elif [ -f "$DST_CLAUDE" ]; then
  # 已存在 → 不覆盖,拷到旁边
  SIDE="$ROOT/CLAUDE.flutter-autonomous.md"
  if cp "$TPL_CLAUDE" "$SIDE"; then
    warn "已存在 CLAUDE.md,未覆盖;模板放到旁边: $SIDE"
    todo "合并 $SIDE 的项目宪法清单(占位/日志锚点/红线)进你现有的 CLAUDE.md,然后删掉它"
    FILLABLE_CLAUDE="$SIDE"   # 旁置文件可回填占位,方便你拷
  else
    err "拷贝失败: $TPL_CLAUDE → $SIDE"
  fi
else
  if cp "$TPL_CLAUDE" "$DST_CLAUDE"; then
    ok "新建 CLAUDE.md: $DST_CLAUDE"
    FILLABLE_CLAUDE="$DST_CLAUDE"
  else
    err "拷贝失败: $TPL_CLAUDE → $DST_CLAUDE"
  fi
fi

# ── 4. 装 .claude/(commands + settings.json) ──────────────────────
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

# ── 5. 自动探测并回填占位(尽力而为,探测不到留 {{...}} 让用户填) ──
echo
printf '%s── 自动探测并回填占位 ──%s\n' "$C_B" "$C_0"

# 5a. Android applicationId ← android/app/build.gradle(.kts)
#     Groovy:  applicationId "com.example.myapp"
#     Kotlin:  applicationId = "com.example.myapp"
ANDROID_ID=""
for g in "$ROOT/android/app/build.gradle" "$ROOT/android/app/build.gradle.kts"; do
  [ -f "$g" ] || continue
  # 取第一处真正的 applicationId(排除 applicationIdSuffix);兼容有无 `=`、单双引号
  ANDROID_ID=$(grep -E '^\s*applicationId\s*(=)?\s*["'\'']' "$g" 2>/dev/null \
    | grep -v 'applicationIdSuffix' \
    | head -1 \
    | sed -E 's/.*applicationId[[:space:]]*=?[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/')
  [ -n "$ANDROID_ID" ] && break
done
if [ -n "$ANDROID_ID" ]; then
  ok "探测 applicationId = $ANDROID_ID"
else
  warn "未探测到 applicationId(占位 {{ANDROID_APPLICATION_ID}} 保留,请手填)"
fi

# 5b. iOS bundleId ← ios/Runner.xcodeproj/project.pbxproj
#     行形如:  PRODUCT_BUNDLE_IDENTIFIER = com.example.myapp;
#     可能有多条(Debug/Release/Profile + RunnerTests),取非 Tests 的 app 目标值
IOS_ID=""
PBX="$ROOT/ios/Runner.xcodeproj/project.pbxproj"
if [ -f "$PBX" ]; then
  IOS_ID=$(grep 'PRODUCT_BUNDLE_IDENTIFIER' "$PBX" 2>/dev/null \
    | grep -vE 'RunnerTests|\.Tests|UITests' \
    | head -1 \
    | sed -E 's/.*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*"?([^";]+)"?;?.*/\1/' \
    | sed -E 's/[[:space:]]*$//')
fi
if [ -n "$IOS_ID" ]; then
  ok "探测 iOS bundleId = $IOS_ID"
else
  warn "未探测到 iOS bundleId(占位 {{IOS_BUNDLE_ID}} 保留;Linux 无 iOS 工具链可忽略)"
fi

# 5c. Dart 包名 ← pubspec.yaml 的 name:
DART_PKG=""
DART_PKG=$(grep -E '^name:[[:space:]]*' "$ROOT/pubspec.yaml" 2>/dev/null \
  | head -1 \
  | sed -E 's/^name:[[:space:]]*//' \
  | sed -E 's/[[:space:]]+#.*$//' \
  | tr -d '"'\''[:space:]')
if [ -n "$DART_PKG" ]; then
  ok "探测 Dart 包名 = $DART_PKG"
else
  warn "未探测到 Dart 包名(占位 {{DART_PACKAGE}} 保留,请手填)"
fi

# 5d. 回填到本次新建/旁置的 CLAUDE.md(绝不动用户原有 CLAUDE.md)
if [ -n "$FILLABLE_CLAUDE" ] && [ -f "$FILLABLE_CLAUDE" ]; then
  [ -n "$ANDROID_ID" ] && sed_replace "$FILLABLE_CLAUDE" "{{ANDROID_APPLICATION_ID}}" "$ANDROID_ID"
  [ -n "$IOS_ID" ]     && sed_replace "$FILLABLE_CLAUDE" "{{IOS_BUNDLE_ID}}"          "$IOS_ID"
  [ -n "$DART_PKG" ]   && sed_replace "$FILLABLE_CLAUDE" "{{DART_PACKAGE}}"           "$DART_PKG"
  # APP_NAME 默认用 Dart 包名兜底(用户可改),仅当探到包名才填,避免留半截
  [ -n "$DART_PKG" ]   && sed_replace "$FILLABLE_CLAUDE" "{{APP_NAME}}"               "$DART_PKG"
  info "已把探到的值回填进 $(basename "$FILLABLE_CLAUDE");未探到的占位保持 {{...}} 待你填"
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

printf '%s剩余占位(若上面有 warn 未探到):%s 编辑 %s,把 %s{{...}}%s 填满(日志锚点 / 工具链 / 共存 App / 红线必须手填)\n' \
  "$C_B" "$C_0" "$ROOT/CLAUDE.md" "$C_DIM" "$C_0"
echo
printf '%s下一步:%s\n' "$C_B" "$C_0"
printf '  1) 环境自举(装 mobilecli / patrol / 体检):%sbash %s/scripts/bootstrap.sh%s\n' "$C_DIM" "$SKILL_DIR" "$C_0"
printf '  2) 填满 %s/CLAUDE.md 剩余占位\n' "$ROOT"
printf '  3) 在项目里跑 %s/ship%s 走「实现→测试→修复→提交」闭环\n' "$C_DIM" "$C_0"
echo

exit 0

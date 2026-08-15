#!/usr/bin/env bash
# flutter-autonomous skill — one command to install the templates into any Flutter project
#
# Usage:
#   bash setup-project.sh [<project-root>]      # defaults to the current directory
#
# What it does (all reversible, re-runnable, never overwrites without a backup):
#   1) Verifies the target really is a Flutter project (has pubspec.yaml)
#   2) Installs .claude/commands/* (each existing file backed up as .bak) plus
#      settings.json (if one already exists, the template is dropped next to it
#      for you to merge with jq)
#   3) Prints what was installed / what still needs your hands
#
# It only writes into <project-root>/.claude/ and never touches your project root:
# package name, both platform ids and the entry point are detected by the skill at
# runtime, and the device is taken live — there is nothing for you to configure up front.
#
# Design notes: set -u guards undefined variables; set -e is deliberately NOT on
#               (we want to report every item, not bail on the first failure);
#               macOS (BSD sed) and Linux (GNU sed) compatible — in-place edits always
#               go through a temp file rather than -i.
set -u

# ── Colors (degrade to empty strings without a TTY, so pipes stay clean) ───────
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_B=''; C_0=''
fi
ok()   { printf '%s✓%s %s\n'  "$C_OK"   "$C_0" "$*"; }
warn() { printf '%s!%s %s\n'  "$C_WARN" "$C_0" "$*"; }
err()  { printf '%s✗%s %s\n'  "$C_ERR"  "$C_0" "$*" >&2; }
info() { printf '%s· %s%s\n'  "$C_DIM"  "$*" "$C_0"; }

# Collect the "you have to do this yourself" items and print them together at the end
MANUAL_TODOS=()
todo() { MANUAL_TODOS+=("$1"); }

# ── 1. Parse arguments + verify this is a Flutter project ─────────────────────
ROOT_ARG="${1:-.}"
# Resolve to an absolute path (the directory must already exist)
if [ ! -d "$ROOT_ARG" ]; then
  err "Target directory does not exist: $ROOT_ARG"
  exit 1
fi
ROOT="$(cd "$ROOT_ARG" && pwd)"

if [ ! -f "$ROOT/pubspec.yaml" ]; then
  err "Not a Flutter project: no pubspec.yaml under $ROOT"
  err "Usage: bash setup-project.sh <flutter-project-root>"
  exit 1
fi
ok "Target Flutter project: $ROOT"

# ── 2. Locate the skill package root (the directory this script lives in) ─────
# Works through source / symlinks: prefer BASH_SOURCE
SELF="${BASH_SOURCE[0]:-$0}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
TPL_DIR="$SKILL_DIR/templates"
SCRIPTS_DIR="$SKILL_DIR/scripts"

if [ ! -d "$TPL_DIR" ]; then
  err "Template directory not found: $TPL_DIR (this script must sit at the skill package root)"
  exit 1
fi
info "Skill package root: $SKILL_DIR"

# Timestamp suffix for backups
TS="$(date +%Y%m%d-%H%M%S)"

# ── 3. Install .claude/ (commands + settings.json) ────────────────────────────
echo
printf '%s── .claude/ (commands + settings.json) ──%s\n' "$C_B" "$C_0"
DST_DOTCLAUDE="$ROOT/.claude"
DST_CMDS="$DST_DOTCLAUDE/commands"
mkdir -p "$DST_CMDS"

# 4a. The 5 commands (spec / verify / ship / debug / nightly)
TPL_CMDS="$TPL_DIR/.claude/commands"
CMD_NAMES="spec verify ship debug nightly"
if [ -d "$TPL_CMDS" ]; then
  for name in $CMD_NAMES; do
    src="$TPL_CMDS/$name.md"
    dst="$DST_CMDS/$name.md"
    if [ ! -f "$src" ]; then
      warn "Command template missing, skipping: $name.md (not shipped in this skill package)"
      continue
    fi
    if [ -f "$dst" ]; then
      bak="$dst.bak.$TS"
      if cp "$dst" "$bak" && cp "$src" "$dst"; then
        warn "$name.md already existed → backed up as $(basename "$bak"), then overwritten"
      else
        err "Update failed: $name.md"
      fi
    else
      if cp "$src" "$dst"; then
        ok "Installed command: .claude/commands/$name.md"
      else
        err "Copy failed: $name.md"
      fi
    fi
  done
else
  warn "No .claude/commands/ in the templates — skipping all 5 commands (this skill package ships no command templates)"
  todo "Add templates/.claude/commands/{spec,verify,ship,debug,nightly}.md to the skill package, then re-run this script"
fi

# 4b. settings.json — never overwritten directly
TPL_SET="$TPL_DIR/.claude/settings.json"
DST_SET="$DST_DOTCLAUDE/settings.json"
if [ ! -f "$TPL_SET" ]; then
  warn "Template missing, skipping settings.json: $TPL_SET"
elif [ -f "$DST_SET" ]; then
  SIDE_SET="$DST_DOTCLAUDE/settings.flutter-autonomous.json"
  if cp "$TPL_SET" "$SIDE_SET"; then
    warn ".claude/settings.json already exists and was NOT overwritten; the template is next to it: $SIDE_SET"
    todo "Merge permissions.allow / permissions.deny / hooks from $SIDE_SET into your existing settings.json with jq, e.g.:"
    todo "  jq -s '.[0].permissions.allow = ((.[0].permissions.allow // []) + (.[1].permissions.allow // []) | unique) | .[0].hooks = (.[0].hooks // .[1].hooks) | .[0]' .claude/settings.json $(basename "$SIDE_SET") > .claude/settings.merged.json && mv .claude/settings.merged.json .claude/settings.json"
  else
    err "Copy failed: $TPL_SET → $SIDE_SET"
  fi
else
  if cp "$TPL_SET" "$DST_SET"; then
    ok "Created .claude/settings.json (permission allowlist + format/analyze hook)"
  else
    err "Copy failed: $TPL_SET → $DST_SET"
  fi
fi

# ── Wrap up: what was installed / what you must do / what's next ──────────────
echo
printf '%s═══ Setup complete ═══%s\n' "$C_B" "$C_0"
echo
if [ "${#MANUAL_TODOS[@]}" -gt 0 ]; then
  printf '%sNeeds your hands:%s\n' "$C_WARN" "$C_0"
  for t in "${MANUAL_TODOS[@]}"; do
    printf '  %s- %s%s\n' "$C_WARN" "$t" "$C_0"
  done
  echo
fi

printf '%sNext steps:%s\n' "$C_B" "$C_0"
printf '  1) Bootstrap the environment (install mobilecli / patrol, run the checks): %sbash %s/scripts/bootstrap.sh%s\n' "$C_DIM" "$SKILL_DIR" "$C_0"
printf '  2) In your project, run %s/ship%s to drive the implement → verify-on-device → fix → commit loop\n' "$C_DIM" "$C_0"
echo
printf '%sNo configuration needed to start%s: package name / both platform ids / entry point are detected by the AI, and the device is taken live.\n' "$C_DIM" "$C_0"
printf '%sOnly for unattended runs (/nightly, /schedule) is it worth spelling out in your own CLAUDE.md: project-specific red lines, red-line authorization exceptions, commit policy%s\n' "$C_DIM" "$C_0"
printf '%s— that is when nobody is around to ask, and the AI goes strictly by what is written down (any unauthorized red line is skipped).%s\n' "$C_DIM" "$C_0"
echo

exit 0

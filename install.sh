#!/usr/bin/env bash
# flutter-autonomous — one-command installer for the skill itself (new machine friendly).
#
#   Remote (no checkout needed):
#     curl -fsSL https://raw.githubusercontent.com/z-chu/flutter-autonomous-skill/main/install.sh | bash
#
#   From a local checkout:
#     bash install.sh            # symlink the skill into ~/.claude/skills (default, auto-updates with git pull)
#     bash install.sh --copy     # copy instead of symlink (frozen snapshot)
#
# What it does (idempotent, never destroys your data):
#   1) Locates the skill source — a local checkout if run from one, otherwise
#      clones the repo into ~/.claude/flutter-autonomous-skill (git pull if already cloned)
#   2) Installs skills/flutter-autonomous into ~/.claude/skills/flutter-autonomous
#      (symlink by default; pre-existing directories are backed up, never deleted)
#   3) Prints next steps (bootstrap dependencies / set up your Flutter project)
#
# Note: this installs the SKILL for Claude Code. To install the project templates
# into a Flutter project, run the skill's own setup script afterwards:
#   bash ~/.claude/skills/flutter-autonomous/setup-project.sh <flutter-project-root>
set -u

REPO_URL="${FLUTTER_AUTONOMOUS_REPO:-https://github.com/z-chu/flutter-autonomous-skill.git}"
CLONE_DIR="$HOME/.claude/flutter-autonomous-skill"
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
DEST="$SKILLS_DIR/flutter-autonomous"
MODE="link"
[ "${1:-}" = "--copy" ] && MODE="copy"

if [ -t 1 ]; then C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else C_OK=''; C_WARN=''; C_ERR=''; C_B=''; C_0=''; fi
ok()   { printf '%s✓%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_0" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_ERR" "$C_0" "$*" >&2; }

# ── 1. Locate the skill source ──────────────────────────────────────────────
# If this script lives inside a checkout (skills/flutter-autonomous/SKILL.md next
# to it), use that. Otherwise (e.g. piped via curl) clone/update the repo.
SRC=""
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  CHECKOUT="$(cd "$(dirname "$SELF")" && pwd)"
  [ -f "$CHECKOUT/skills/flutter-autonomous/SKILL.md" ] && SRC="$CHECKOUT/skills/flutter-autonomous"
fi

if [ -z "$SRC" ]; then
  if ! command -v git >/dev/null 2>&1; then
    err "git is required for remote install. Install git, or clone the repo manually and run: bash install.sh"
    exit 1
  fi
  if [ -d "$CLONE_DIR/.git" ]; then
    ok "Existing clone found: $CLONE_DIR — updating"
    git -C "$CLONE_DIR" pull --ff-only 2>/dev/null || warn "git pull failed (offline?) — using the existing clone as-is"
  else
    ok "Cloning $REPO_URL → $CLONE_DIR"
    git clone --depth 1 "$REPO_URL" "$CLONE_DIR" || { err "git clone failed — check network / URL"; exit 1; }
  fi
  SRC="$CLONE_DIR/skills/flutter-autonomous"
fi

[ -f "$SRC/SKILL.md" ] || { err "Skill source is broken: $SRC/SKILL.md not found"; exit 1; }
ok "Skill source: $SRC"

# ── 2. Install into ~/.claude/skills ────────────────────────────────────────
mkdir -p "$SKILLS_DIR"

# Already the right symlink? Done.
if [ -L "$DEST" ] && [ "$(readlink "$DEST")" = "$SRC" ] && [ "$MODE" = "link" ]; then
  ok "Already installed (symlink up to date): $DEST → $SRC"
else
  # Back up anything that's currently there (never delete user data).
  # NOTE: the backup must live OUTSIDE the skills dir — a SKILL.md left inside
  # ~/.claude/skills/ would be loaded as a duplicate skill by Claude Code.
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    BAK="$(dirname "$SKILLS_DIR")/flutter-autonomous.bak.$(date +%Y%m%d-%H%M%S)"
    mv "$DEST" "$BAK"
    warn "Existing $DEST moved to: $BAK (delete it yourself once you're happy)"
  fi
  if [ "$MODE" = "link" ]; then
    ln -s "$SRC" "$DEST"
    ok "Symlinked: $DEST → $SRC  (updates automatically when the checkout is git pulled)"
  else
    cp -R "$SRC" "$DEST"
    ok "Copied: $DEST  (frozen snapshot; re-run installer to update)"
  fi
fi

# ── 3. Verify + next steps ──────────────────────────────────────────────────
[ -f "$DEST/SKILL.md" ] || { err "Install verification failed: $DEST/SKILL.md unreadable"; exit 1; }
ok "Verified: $DEST/SKILL.md is readable"

echo
printf '%s═══ flutter-autonomous installed ═══%s\n' "$C_B" "$C_0"
cat <<EOF

Next steps:
  1) Restart Claude Code (new skills are picked up on startup).
  2) Bootstrap dependencies (flutter/mobilecli/patrol/adb/Xcode checks, installs what it can):
       bash $DEST/scripts/bootstrap.sh
  3) Wire up your Flutter project (CLAUDE.md constitution + /spec /ship /verify /debug /nightly commands):
       bash $DEST/setup-project.sh <your-flutter-project-root>
  4) In your project, just tell Claude:
       /ship <one-line feature>     — or —     "run the app on a device and verify X"

Docs: https://github.com/z-chu/flutter-autonomous-skill
EOF

#!/usr/bin/env bash
# check-mirror.sh — keep the zh/ → English mirror from silently falling behind
#                   (maintainer tool; not shipped with the skill)
#
# Background: the README says "the Chinese zh/ copy is the source of truth, the English
# files are synced afterwards". That is an honor-system rule, and it has failed before —
# the mirror was once a full version behind (missing §0, missing the entire VM Service
# route, still advertising a usage that had been dropped). English users were getting
# behavior the Chinese side had already rejected, and nothing in the repo looked wrong.
# This script turns that incident into a check a machine can run.
#
# Usage:
#   bash tools/check-mirror.sh              # structure check: are the files paired, do heading/code-fence counts line up
#   bash tools/check-mirror.sh --diff main  # change check: this branch touched zh/ but not the English counterpart → error
#
# Exit codes: 0 = pass; 1 = problems found (usable directly in CI / a pre-push hook)
#
# Deliberately out of scope: it does not compare wording and does not judge translation
# quality — that is a human call. It answers exactly one question: "could this change have
# landed on only one side?" Missing a case beats crying wolf until nobody runs it any more.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/flutter-autonomous"
ZH="$SKILL/zh"
FAIL=0

c_red=$'\033[31m'; c_yel=$'\033[33m'; c_grn=$'\033[32m'; c_dim=$'\033[2m'; c_0=$'\033[0m'
err()  { printf '%s✗%s %s\n' "$c_red" "$c_0" "$*"; FAIL=1; }
warn() { printf '%s!%s %s\n' "$c_yel" "$c_0" "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_grn" "$c_0" "$*"; }

# The zh/ files that must have a counterpart (paths relative to $ZH). scripts/ is code and
# is not translated, so it is not in the list.
mirrored_files() {
  (cd "$ZH" && find . -name '*.md' | sed 's|^\./||' | sort)
  (cd "$ZH" && find templates -type f -name '*.json' 2>/dev/null | sort)
}

# Code blocks must be skipped: a shell comment `# foo` looks exactly like an h1, so a plain
# grep counts comments inside command examples as headings, and the slightest difference in
# comment style between the two sides is a false alarm — false alarms are why people stop
# running a script like this.
count_headings() {
  awk '/^```/ { inb = !inb; next } !inb && /^#{1,6} / { n++ } END { print n+0 }' "$1"
}
count_fences() { grep -c '^```' "$1" 2>/dev/null; true; }

structure_check() {
  echo "Structure check: $ZH → English (skills/flutter-autonomous)"
  echo
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    zh="$ZH/${rel}"; en="$SKILL/${rel}"
    if [ ! -f "$en" ]; then
      err "missing English mirror: ${rel}"
      continue
    fi
    zh_h=$(count_headings "$zh"); en_h=$(count_headings "$en")
    zh_f=$(count_fences   "$zh"); en_f=$(count_fences   "$en")
    if [ "$zh_h" -ne "$en_h" ]; then
      err "${rel}: heading count zh=$zh_h en=$en_h ${c_dim}(usually a section that was never synced across)${c_0}"
    elif [ "$zh_f" -ne "$en_f" ]; then
      err "${rel}: code-block count zh=$zh_f en=$en_f ${c_dim}(a command example landed on only one side)${c_0}"
    else
      ok  "${rel} ${c_dim}(headings $zh_h / code blocks $((zh_f/2)))${c_0}"
    fi
  done < <(mirrored_files)

  # Reverse: English files with no counterpart on the Chinese side
  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    [ -f "$ZH/${rel}" ] || warn "${rel} has no counterpart under zh/ (renamed and forgot to delete?)"
  done < <(cd "$SKILL" 2>/dev/null && find . -name '*.md' -not -path './zh/*' | sed 's|^\./||' | sort)
}

diff_check() {
  local base="$1"
  git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1 || {
    err "baseline '$base' is not a valid git ref"; return
  }
  echo "Change check: against $base"
  echo
  # Two-dot diff (not base...HEAD): this counts [uncommitted working-tree changes] too —
  # the moment a maintainer most needs this script is "just finished editing, not committed yet",
  # and a three-dot range is exactly blind to those changes.
  local changed
  changed=$(git -C "$ROOT" diff --name-only "$base" -- skills/flutter-autonomous 2>/dev/null)
  # Newly created files that have not been git added yet are not in the diff, so add them
  changed=$(printf '%s\n%s\n' "$changed" \
    "$(git -C "$ROOT" ls-files --others --exclude-standard -- skills/flutter-autonomous)" | sed '/^$/d' | sort -u)
  [ -n "$changed" ] || { ok "no changes, skipping"; return; }

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      *.md) ;;
      *) continue ;;                                     # translated files only
    esac
    case "$path" in
      skills/flutter-autonomous/zh/*) ;;                 # checks are only initiated from the zh side
      *) continue ;;
    esac
    rel="${path#skills/flutter-autonomous/zh/}"
    counterpart="skills/flutter-autonomous/${rel}"
    # Deletion is a change too: if the Chinese file is gone, the English one must go with it —
    # otherwise an orphaned English doc is left behind with nobody maintaining it
    if [ ! -f "$ROOT/$path" ]; then
      if [ -f "$ROOT/$counterpart" ]; then
        err "deleted zh/${rel}, ${c_dim}but${c_0} ${rel} is still there ${c_dim}→ leaves an unmaintained orphan${c_0}"
      else
        ok  "zh/${rel} and ${rel} were deleted together"
      fi
      continue
    fi
    [ -f "$ROOT/$counterpart" ] || { err "changed zh/${rel}, but it has no English mirror"; continue; }
    if grep -qxF "$counterpart" <<<"$changed"; then
      ok  "zh/${rel} and ${rel} were changed together"
    else
      err "changed zh/${rel}, ${c_dim}but${c_0} ${rel} did not move ${c_dim}→ English users would get the old behavior${c_0}"
    fi
  done <<<"$changed"
}

case "${1:-}" in
  --diff) diff_check "${2:-main}" ;;
  ""|--structure) structure_check ;;
  *) echo "Usage: $0 [--structure | --diff <base-ref>]" >&2; exit 2 ;;
esac

echo
if [ "$FAIL" -eq 0 ]; then
  ok "mirror in sync"
else
  printf '%smirror out of sync%s — zh/ is the source of truth; port the missing part into the English files before committing.\n' "$c_red" "$c_0"
fi
exit "$FAIL"

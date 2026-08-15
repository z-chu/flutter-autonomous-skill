#!/usr/bin/env bash
# tap-by-label.sh — tap the center of an element by label substring, in one step (filling the
# gap where mobilecli/mobile-mcp only offer coordinate-level `io tap` and have no native
# "tap by label" command). Zero dependencies beyond mobilecli + jq.
#
# Usage:
#   tap-by-label.sh <deviceId> <labelSubstring> [--index N] [--dump-only]
#
# Arguments:
#   <deviceId>        device id from `mobilecli devices` (the script hardcodes no device; pass it at runtime)
#   <labelSubstring>  substring to match; tested as "contains" (case-insensitive) against each node's
#                     identifier / label / text / name
#                     Prefer passing an identifier (the stable id from Semantics(identifier:)) — it does
#                     not change when the copy or the language changes
#   --index N         tap the Nth match when there are several (0-based; default 0)
#   --dump-only       only list every match (label + center coordinates) without tapping — look first, then decide
#
# How it works:
#   1) `mobilecli dump ui --device "$D" --format json` returns the ScreenElement tree
#      node shape: {type,label?,text?,name?,value?,placeholder?,identifier?,
#                   rect:{x,y,width,height — integer physical pixels},children:[]}
#   2) jq recurses through recurse(.children[]?), matching any of label/text/name containing the
#      substring (case-insensitive), and computes the center (rect.x + rect.width/2, rect.y + rect.height/2)
#   3) Matches are sorted by rect area **ascending** — after Semantics merging, an ancestor container's
#      label naturally contains the substring too, and jq's `..` is a pre-order traversal (parent before
#      child), so without sorting [0] is very often the whole row / whole Card; tapping that lands on
#      blank space inside the container = "the tap did nothing". The smallest one is the leaf widget you meant.
#   4) --dump-only just lists; otherwise it taps match number --index: mobilecli io tap --device "$D" <cx>,<cy>
#
# Note: the emitted TSV puts the coordinates first and the label last, escaped through @tsv — Flutter's
#      Semantics merging frequently produces **labels containing newlines** (e.g. "SOL\n$123.45\n+2.3%"),
#      and an unescaped label in the first column blows one row into several, wrecking the line count,
#      reading back empty coordinates and tapping (0,0).
#
# Exit codes: 0 success; 1 usage error; 2 missing dependency (jq/mobilecli); 3 dump failed;
#             4 no match; 5 --index out of range

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: tap-by-label.sh <deviceId> <labelSubstring> [--index N] [--dump-only]

  <deviceId>        device id from `mobilecli devices`
  <labelSubstring>  substring matched as "contains" (case-insensitive) against identifier/label/text/name
                    prefer an identifier — it survives copy and language changes, a label does not
  --index N         tap the Nth match when there are several (0-based; defaults to 0)
  --dump-only       only list every match (label + center coordinates), without tapping

Examples:
  tap-by-label.sh <deviceId> "Submit"               # tap the first widget containing "Submit"
  tap-by-label.sh <deviceId> "Buy" --dump-only      # see what matches first
  tap-by-label.sh <deviceId> "Buy" --index 1        # tap the 2nd match
EOF
  exit 1
}

# ---- Parse arguments ---------------------------------------------------------
DEVICE=""
NEEDLE=""
INDEX=0
DUMP_ONLY=0
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --index)
      [ $# -ge 2 ] || { echo "Error: --index requires a numeric argument" >&2; usage; }
      INDEX="$2"; shift 2 ;;
    --index=*)
      INDEX="${1#*=}"; shift ;;
    --dump-only)
      DUMP_ONLY=1; shift ;;
    -h|--help)
      usage ;;
    --*)
      echo "Error: unknown option '$1'" >&2; usage ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done

# Positional arguments: deviceId + labelSubstring (both required)
[ "${#POSITIONAL[@]}" -ge 2 ] || { echo "Error: missing <deviceId> or <labelSubstring>" >&2; usage; }
DEVICE="${POSITIONAL[0]}"
NEEDLE="${POSITIONAL[1]}"

# --index must be a non-negative integer
case "$INDEX" in
  ''|*[!0-9]*) echo "Error: --index must be a non-negative integer, got '$INDEX'" >&2; usage ;;
esac

# ---- Dependency checks -------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq not found — this script relies on jq to parse the dump ui JSON." >&2
  echo "  macOS:  brew install jq" >&2
  echo "  Linux:  apt install jq   (or the yum/dnf/apk equivalent)" >&2
  exit 2
fi
if ! command -v mobilecli >/dev/null 2>&1; then
  echo "Error: mobilecli not found — the interaction base is missing." >&2
  echo "  Install: npm i -g mobilecli@latest   (or npx mobilecli@latest)" >&2
  exit 2
fi

# ---- Grab the UI tree --------------------------------------------------------
# dump ui --format json: the whole ScreenElement tree, rect in integer physical pixels
UI_JSON="$(mobilecli dump ui --device "$DEVICE" --format json 2>/dev/null)" || {
  echo "Error: mobilecli dump ui failed — is device '$DEVICE' online, and is the target app in the foreground?" >&2
  echo "  Check with: mobilecli devices   /   mobilecli apps foreground --device '$DEVICE'" >&2
  exit 3
}
if [ -z "$UI_JSON" ]; then
  echo "Error: dump ui returned nothing — device '$DEVICE' may be offline or have no foreground app." >&2
  exit 3
fi

# ---- Recursive match + center calculation ------------------------------------
# Emits one TSV line per match: <cx>\t<cy>\t<area>\t<label>
#   Coordinates first, label last: newlines/tabs inside a label can no longer break the row structure
#   (on top of @tsv escaping + whitespace folding)
#   label = the first non-empty of label / text / name / identifier (display only)
#   Match rule: any of identifier/label/text/name (lowercased) contains the needle (lowercased)
#     ★ identifier = Flutter `Semantics(identifier:)` (3.19+), mapped to Android resource-id /
#       iOS accessibilityIdentifier. It is **a stable id meant for automation and does not change with
#       copy or language**, whereas label is the human-visible text — in a multi-language project,
#       locating by label breaks the moment the copy changes. If an identifier exists, pass that.
#   Center: x + width/2, y + height/2 (floored, matching mobilecli io tap's pixel semantics)
#   Sort: by rect area ascending — the smallest is most likely the leaf widget rather than the
#         row/card container wrapping it
MATCHES="$(printf '%s' "$UI_JSON" | jq -r --arg needle "$NEEDLE" '
  ($needle | ascii_downcase) as $q
  | [ .. | objects | select(has("rect"))
      | . as $n
      | ( [ ($n.identifier // ""), ($n.label // ""), ($n.text // ""), ($n.name // "") ]
          | map(ascii_downcase) ) as $hay
      | select( any($hay[]; contains($q)) )
      | {
          label: ( ($n.label // $n.text // $n.name // $n.identifier // "(no label)")
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
  echo "Error: jq failed to parse the dump ui output (unexpected JSON shape?)" >&2
  exit 3
}

# No match — name the most likely root causes (no Semantics exposed / pure canvas) and point back at the code
if [ -z "$MATCHES" ]; then
  echo "No element containing '$NEEDLE' was found." >&2
  echo "Likely causes:" >&2
  echo "  1) The widget exposes no Semantics — custom gesture widgets (Touchable/GestureDetector/InkWell)" >&2
  echo "     do not show up in a dump by default; wrap them explicitly in Semantics(label: ..., button: true)." >&2
  echo "  2) Pure canvas painting (inside a chart, etc.) with no Semantics wrapper — go back to the code and add" >&2
  echo "     Semantics(label:), or fall back to measuring coordinates from a screenshot for such nodes (last resort)." >&2
  echo "  3) Spelling is off (case does not matter, content does) — list everything first:" >&2
  echo "       mobilecli dump ui --device '$DEVICE' --format json | jq -r '.. | objects | select(has(\"rect\")) | [.identifier, .label, .text, .name] | map(select(. != null)) | @tsv'" >&2
  exit 4
fi

# Count the matches
COUNT="$(printf '%s\n' "$MATCHES" | wc -l | tr -d ' ')"

# ---- --dump-only: list without tapping ---------------------------------------
if [ "$DUMP_ONLY" -eq 1 ]; then
  echo "Matches containing '$NEEDLE' ($COUNT, by ascending area, 0-based index):"
  i=0
  while IFS=$'\t' read -r cx cy area label; do
    printf '  [%d] %-40s center=(%s,%s) area=%s\n' "$i" "$label" "$cx" "$cy" "$area"
    i=$((i + 1))
  done <<< "$MATCHES"
  echo "Hint: the large ones are usually the row/card container wrapping your target — tapping them lands on blank space. Use --index N to pick one (the default taps [0] = the smallest)." >&2
  exit 0
fi

# ---- Select the target + range check -----------------------------------------
if [ "$INDEX" -ge "$COUNT" ]; then
  echo "Error: --index $INDEX is out of range — only $COUNT matches contain '$NEEDLE' (valid indices 0..$((COUNT - 1)))." >&2
  echo "  See them all first: tap-by-label.sh '$DEVICE' '$NEEDLE' --dump-only" >&2
  exit 5
fi

# Several matches and no explicit index — say so, and tap [0] (the smallest) this time
if [ "$COUNT" -gt 1 ] && [ "$INDEX" -eq 0 ]; then
  echo "Warning: $COUNT matches contain '$NEEDLE'; tapping the smallest one, [0], by default. If that is wrong, pick with --index N (use --dump-only to see them all first)." >&2
fi

# Take line INDEX (sed line numbers start at 1, hence +1)
TARGET_LINE="$(printf '%s\n' "$MATCHES" | sed -n "$((INDEX + 1))p")"
IFS=$'\t' read -r CX CY AREA LABEL <<< "$TARGET_LINE"

# Coordinate sanity check: anything that mangled the row structure gets caught here,
# instead of silently tapping (0,0)
for v in "${CX:-}" "${CY:-}"; do
  case "$v" in
    ''|*[!0-9]*) echo "Error: parsed coordinates are invalid (cx='${CX:-}' cy='${CY:-}', raw line: $TARGET_LINE)." >&2; exit 3 ;;
  esac
done

# ---- Tap + echo the evidence -------------------------------------------------
mobilecli io tap --device "$DEVICE" "$CX,$CY" >/dev/null || {
  echo "Error: mobilecli io tap failed (device '$DEVICE', coordinates $CX,$CY)." >&2
  exit 3
}
echo "Tapped [index $INDEX] label='$LABEL' center=($CX,$CY) area=$AREA device='$DEVICE'"

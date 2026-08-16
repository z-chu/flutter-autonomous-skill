# Cross-screen verification — proving what one screenful can't show

`dump ui` returns the **viewport**, not the list. So any property whose correctness spans more content than fits on screen — pagination order, no-duplicates across page boundaries, "does it actually reach the end", grouping headers on a timeline — **cannot be judged from a single dump, and cannot be judged by eye at all**: the failure is typically hundreds of items down, where nobody scrolls by hand.

The answer always has the same shape: **collect screen by screen → stitch into one global sequence → assert on that sequence with code**.

## When you need it

Any list that pages, streams, or groups: transaction history, chat logs, feeds, search results, leaderboards, log viewers, infinite tables. The tell is a requirement that talks about **the whole list** — "sorted", "no duplicates", "loads more correctly", "reaches the end" — while the screen only ever shows you a window into it.

If the whole thing fits on one screen, don't do any of this: dump once and assert.

## The method

### 1. Collect — one dump per scroll step, **to disk**

```bash
D=<deviceId>
for i in $(seq 1 40); do
  mobilecli io swipe --device $D 540,1700,540,500 >/dev/null 2>&1
  sleep 1.8                                    # let the list settle AND let a page load
  mobilecli dump ui --device $D > /tmp/scan_$i.json
done
```

Scroll distance must be **less than a viewport** so consecutive dumps overlap — the stitcher needs that overlap to know how the screens join up. A fling that jumps three screens silently drops items and you'll never know what you missed.

### 2. Stitch — dedupe by overlap, preserve order

Walk the rounds in order; within a round sort nodes by `rect.y`; append any item not seen before. The overlap between consecutive rounds collapses automatically, and what you get is the list as it actually is, top to bottom.

### 3. Assert — three machine-decidable criteria

| Criterion | How to decide it | Why this exact form |
|---|---|---|
| **No true duplicates** | an item whose set of rounds is **non-contiguous** (appears in round 3 and again in round 9) | Adjacent-round repeats are just viewport overlap and are **expected**. Only a reappearance after a gap means the list really contains it twice. Counting raw repeats gives you a false positive on every single item. |
| **Ordering is monotonic** | walk the stitched sequence, flag any adjacent pair that goes the wrong way | This is where paging bugs live — usually only at the tail, where two data sources ran out at different depths |
| **Group headers unique and ordered** | collect the date/section headers, check for repeats and direction | A repeated header means the same group got emitted twice from different pages |

Report the **count** of violations plus the first few offenders with their neighbours. "0 out-of-order / 0 duplicates" is a result you can act on; "looks fine" is not.

## Reusable skeleton

Write it once to a file and call it with a prefix — you will run it many times, and re-typing it inline is how transcription bugs get in.

```python
# /tmp/analyze.py <prefix>   → reads /tmp/<prefix>_*.json
import json, re, sys, glob
from collections import defaultdict

PAT = re.compile(r'<every text variant an item can start with>')   # see trap 1
files = sorted(glob.glob(f'/tmp/{sys.argv[1]}_*.json'),
               key=lambda f: int(re.search(r'_(\d+)\.json', f).group(1)))

rounds = {}
for f in files:
    idx = int(re.search(r'_(\d+)\.json', f).group(1))
    items = []
    def walk(o):                      # dump is a nested tree; recurse, don't assume depth
        if isinstance(o, dict):
            label, rect = o.get('label'), o.get('rect') or {}
            if isinstance(label, str) and PAT.search(label) and <not a chrome/chip node>:
                items.append((rect.get('y', 0), label))
            for v in o.values(): walk(v)
        elif isinstance(o, list):
            for v in o: walk(v)
    walk(json.load(open(f)))
    items.sort()                                    # top-to-bottom within the screen
    rounds[idx] = [l for _, l in items]

occ = defaultdict(list)                             # item -> rounds it appeared in
for i, ls in rounds.items():
    for l in ls: occ[l].append(i)

seq, seen = [], set()                               # stitched global sequence
for i in sorted(rounds):
    for l in rounds[i]:
        if l not in seen: seen.add(l); seq.append(l)

gaps = {k: v for k, v in occ.items() if max(v) - min(v) + 1 != len(set(v))}
print(f"unique={len(occ)} true-duplicates={len(gaps)}")
# then parse the ordered field out of each label and check adjacent pairs
```

Keep the per-round data (`rounds`), not just the flattened sequence — the round index is what makes the duplicate criterion decidable.

## Three traps, one wasted round each

### 1. Calibrate the ruler first — and when the verdict looks wrong, suspect the ruler

**Dump one screen and read every label form before you write the filter.** A list rendering "buy / sell" almost certainly also renders "transfer in / transfer out / reward / refund", and a filter that misses one variant doesn't just drop those rows — if headers are merged into the first item of their group (they usually are), **it drops the header too**, and every following item gets attributed to the previous group.

That is exactly how a clean list produces **two impossible-looking ordering violations**. The data was fine; the ruler was short.

> **Rule: when the verdict says "anomaly", verify the judging method before investigating the subject.** A false signal read as real costs more the more conscientiously you chase it.

Cheap calibration: `unique` count should be within a few percent of `total rows collected`, and every group header you can see in a screenshot should appear in your header list. If the counts look odd, the filter is wrong.

### 2. "The screen didn't move" means three different things

| What you see | Actual cause | How to tell it apart |
|---|---|---|
| Dumps identical | The gesture never reached the app | Send the same swipe through the **other channel** (`adb shell input swipe` ↔ `mobilecli io swipe`); if the other one moves, the first was swallowed |
| Dumps identical | **The list is already at the end** — Android's default ClampingScrollPhysics has no overscroll, so a fling at the bottom produces **zero displacement** and zero scroll notifications | Read the end-of-list state marker (see below); a fling at the bottom is a no-op by design, not a failure |
| Dumps identical | Genuinely stuck (a load that never completes) | Only after ruling out the two above |

All three look **byte-identical** in `dump ui`, so you need this decision procedure — otherwise you'll retry gestures forever against a list that simply ended, or declare "reached the end" on a list that's actually hung.

The state marker is what settles it, which leads to:

> **Corollary of "can't be listed = go fix the code": a state you can't tell apart is also a code defect.** A footer that renders a bare spinner for "loading" and `SizedBox.shrink()` for "idle" is **the same nothing** in the semantics tree. Give each state a stable `Semantics(identifier:)` (`paging_footer_loading` / `_nomore` / `_fail`) and one dump answers the question. Without it you're stuck taking screenshots and guessing, then adding temporary logs and hot-reloading — that's three round-trips for what should be one.

### 3. Keep the raw data out of your context

A 40-round scan is 40 dumps of tens of KB each. **Never read them into context.** Dump to files, do the judging in the shell (`jq` / `python`), and read back only the verdict — a few lines. The same applies to `logcat`: filter with `grep`/`sed` in the pipe, not with your eyes.

Screenshots are the expensive ones (~1500–2500 tokens each) and they are **not machine-decidable** — take one only when the judgement genuinely requires human-style looking (visual state of a spinner, layout, colour). For "is this data right", the dump-plus-script path is both cheaper and more reliable.

Done this way a 100-screen sweep costs very little context, and you can run these continuously. Done the naive way — every dump read in full — a single sweep blows the window.

## Cost control: don't scroll if you can jump

Getting a list to its end by swiping is by far the most expensive part of this: ~2.5 s per screen, 100+ screens, and you often need several passes (before the fix, after the fix, final regression). That is minutes per pass, and every swipe is a tool round-trip.

**If the property under test lives deep in the list, add a debug-only way to get there in one step** — a debug-panel button that drives the paging controller until it's exhausted, or a VM Service `evaluate` hook. Then verification becomes: jump to the end → dump → assert. Same principle as the deeplink shortcut in the main doc (§ Element-driven interaction), applied to *state depth* rather than *navigation depth*, and it is usually the single biggest win available.

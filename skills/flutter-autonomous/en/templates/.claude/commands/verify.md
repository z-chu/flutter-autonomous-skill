---
description: Verify the current change — pick the hardest evidence by change type, run the four-layer loop, classify failures and self-fix in ≤5 rounds
allowed-tools: Bash(flutter:*), Bash(flutter run:*), Bash(dart:*), Bash(patrol:*), Bash(adb:*), Bash(xcrun:*), Bash(kill:*), Bash(ps:*), Bash(mobilecli:*), Bash(npx mobilecli:*), Bash(bash scripts/tap-by-label.sh:*), Read, Edit, Write, Grep, Glob
argument-hint: [path to the verification test file (optional; if omitted, runs all of integration_test/)]
---

Verify the current change. The rules, location priority, the dual Key+Semantics annotation, and the two teardown steps all align with the `flutter-autonomous` skill; this command only runs the flow and does not restate the methodology.

## Step 0: pick the "hardest evidence" by change type

Not every change needs Patrol — pick the evidence first, then decide whether to go on-device:

| Change type | Hardest evidence |
|---------|---------|
| WebSocket / RPC connection, state-machine transitions, gating logic | **Logs** (hardest): Android `adb logcat -s flutter` / `flutter logs`; iOS `xcrun simctl spawn <udid> log stream`. grep the connection URL / state name / `RenderFlex overflowed` (with file:line) |
| Visual / layout / color / empty state / Loading | **Screenshot**: `mobilecli screenshot --device <id> -o <out>` → Read and eyeball it |
| Widget interaction / page navigation / data display (one-off) | **Element-driven**: `dump ui` → tap rect center, or `bash scripts/tap-by-label.sh <id> "<label>"` |
| Assertions that must be precise, repeatable, and CI-ready | **Patrol**: by `Key`, emits pass/fail |
| Pure logic (parsing / numerics / state machine / error handling) | **Offline fixture**: `flutter test`, sub-second, no device |

For mixed changes, combine them; don't run Patrol just for the sake of running it.

---

## Step 1: the four-layer loop (fixed order, offline layer runs before Patrol)

```bash
# ① Static: only continue at zero warnings
flutter analyze

# ② Offline fixture layer (sub-second, no device) — go green first, then go on-device, to save device time
#    Pin down pure logic like parsing/numerics/state machine/error handling here; skip this step when there's no test/ directory.
#    A failure here = a pure logic bug; don't go on-device, fix the implementation directly per "failure class C".
flutter test

# ③ Device discovery (never hardcode the id; iOS defaults to the target simulator, details in references/ios.md)
mobilecli devices            # if empty, fall back to adb devices / xcrun simctl list devices booted
```

- analyze has warnings / offline layer fails: **fix first, then continue**; only go on-device once the offline layer is fully green.
- All devices empty: do one round of the skill's environment self-bootstrap recovery (`adb kill-server && adb start-server` / `xcrun simctl boot <udid>`); still empty = device physically disconnected, **stop, output a "device offline" report, do not enter the loop**.

Before going on-device, confirm the foreground is the target package to prevent cross-talk: `mobilecli apps foreground --device <id>`.

```bash
# ④ Device layer (run one or a combination, per the evidence picked in Step 0)
# 4a Element-driven (one-off interaction/navigation/display)
bash scripts/tap-by-label.sh <deviceId> "<label substring>"   # or manually dump ui → io tap rect center
mobilecli screenshot --device <deviceId> -o <out>             # screenshot → Read to verify

# 4b Patrol (precise, repeatable regression) — if $ARGUMENTS has a path, run that file; otherwise run all
patrol test -t $ARGUMENTS --device <deviceId>                 # omit -t if no path given
```

---

## Step 2: classify failures and self-fix (≤5 rounds)

**An assertion failure = a logic bug; fix the implementation, never edit the test to lower the bar.** By round 3 note the directions already tried, by round 4 switch approach, by round 5 stop and output a stuck report.

- **A Compile / build failure**: read the **full** `flutter analyze` output (not just the last line), fix the code, go back to Step 1. If the build keeps failing, do `flutter clean && flutter pub get` and retry.
- **B `found 0 widgets`**: check `Key` spelling → check conditional rendering (`isLoading?`/`isVisible?`) → check whether you need to `.scrollTo()` first. A widget that `dump ui` won't list = no exposed Semantics, **go back to the code and add `Semantics(label:)`**, don't settle for a blind-tap.
- **C Assertion failure (expect mismatch)**: a logic bug, read the implementation and fix, **do not lower the assertion bar**.
- **D crash / timeout**: `mobilecli device crashes list --device <id>` → `... crashes get <crash_id> --device <id>`, read the first stack line in `package:<your_app>/`, fix that spot.
- **E install / disconnect**: `mobilecli devices` to confirm status; retry once, and if it still fails, stop and report.

**Still not passing after round 5**:
```
⚠️ Verification failed (tried 5 rounds)
Failed assertion/symptom: <specifics>
Raw error: <original message>
Directions tried: 1. ... 2. ...
Assessment: <root-cause hypothesis + points needing human decision>
```

---

## Step 3: gather evidence after passing + teardown

- Visual changes: `mobilecli screenshot`, then Read to verify layout/truncation/color/empty state/Loading.
- **Two teardown steps, with a re-check** (`kill flutter run` ≠ closing the App):
```bash
kill "$(cat <PID_FILE>)" 2>/dev/null                       # stop the flutter run host
mobilecli apps terminate --device <id> <packageName>       # actually close the App (smooths over Android/iOS)
mobilecli apps foreground --device <id>                    # re-check: confirm the foreground is no longer the target App
```
**Before declaring "verified / closed", you must re-check the real state with an independent command**, don't treat "I ran kill" as "the App is closed".

---

## Final report

```
## Verification result: ✅ all green / ❌ partial failure

### Evidence used
- connection/state machine → logs: <grep hits>
- interaction/navigation → element-driven / Patrol
- visual → screenshot

### Acceptance criteria
- [x] Criterion 1
- [ ] Criterion 3 (failure note)

### Changes
- lib/xxx.dart: reason
- integration_test/xxx_test.dart: reason

### Screenshots
(key screenshots)

### Outstanding (needs human decision)
None / <specifics>
```

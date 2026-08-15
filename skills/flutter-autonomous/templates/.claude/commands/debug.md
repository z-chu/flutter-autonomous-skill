---
description: Analyze a crash / test failure, gather evidence in parallel → locate root cause by type → fix the implementation → verify → output a root-cause report
allowed-tools: Bash(flutter:*), Bash(flutter run:*), Bash(dart:*), Bash(patrol:*), Bash(adb:*), Bash(xcrun:*), Bash(ps:*), Bash(mobilecli:*), Bash(npx mobilecli:*), Read, Edit, Grep, Glob
argument-hint: [failure description / crash info (optional; if omitted, analyzes the most recent failure)]
---

**Debug target**: $ARGUMENTS (if not provided, analyzes the most recent failure in the current state)

Rules, locating priority, and failure classification all align with the `flutter-autonomous` skill. This command focuses on "locating the root cause"; it may modify the implementation to fix it, but **has no Write permission**—to create new files, use `/ship`.

---

## Step 1: Gather evidence in parallel

No dependencies, **send the whole batch together** (don't hardcode device id in device discovery; iOS logs go through `xcrun simctl spawn`, see references/ios.md):

```bash
# App runtime logs (the hardest evidence for connection / state machine / exception stacks)
flutter logs 2>&1 | tail -120
adb logcat -s flutter -d 2>&1 | tail -120                       # Android; first identify the target App PID to prevent cross-talk

# Crash report
mobilecli devices                                               # get online device id
mobilecli device crashes list --device <id>
# if there's a crash, pull details: mobilecli device crashes get <crash_id> --device <id>

# Static analysis (the root cause of compile-class failures is often here)
flutter analyze 2>&1 | tail -60
```

---

## Step 2: Locate the root cause by type

- **Crash**: in the stack trace find the **first line under `package:<your_app>/`**—that's the code location of the crash, read that section. Skip system/framework frames below it.
- **Assertion failure**: compare "the state the test expected" vs "the state the implementation actually produced", and find the point of logical divergence.
- **`found 0 widgets`**: check `Key` spelling (case/underscore) → check conditional rendering logic → check whether the widget is outside the viewport (needs `scrollTo`) → if the widget doesn't expose `Semantics` at all, then `dump ui` won't list it either, so locate it as the code missing `Semantics`.
- **Compile error**: read the **full** error message (not just the last line); it's usually type / import / missing argument.

Prefer element-driven means and logs for locating: `mobilecli dump ui --device <id>` to see whether the widget is actually exposed and what its label is; `mobilecli screenshot` to see the on-screen state at the time.

---

## Step 3: Fix

- **Fix the implementation, don't change the test to work around the failure** (an assertion failure = a logic bug).
- Only change the test when you've confirmed the test case itself is wrong (misspelled Key name, missing `pumpAndSettle`)—and only after ruling out an implementation problem first.

---

## Step 4: Verify the fix

```bash
flutter analyze                                                 # no new errors
patrol test -t <relevant test file> --device <id>               # re-run to confirm it passes; iOS defaults to simulator
```

---

## Output the root-cause report

```
## Debug Report

Root cause: <one sentence, what the problem is>
Location: <file:line>
Cause analysis: <why it happened>
Fix: 
- <file>: description of the change
Verification: <result of re-running analyze / patrol>
Remaining: none / <points needing manual decision>
```

---
description: Fully autonomous delivery of a single feature: define criteria → implement → four-layer verification → fix → screenshot → (handle the commit per the user's commit policy)
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
argument-hint: [one-line requirement, including "what done looks like"]
---

Requirement: $ARGUMENTS

**Execute fully autonomously.** Reversible low-risk work (installing tools / changing local config / adding dependencies / scaffolding tests) — do it and keep going; red-line operations (real money / secrets & credentials / irreversible destruction, plus the project CLAUDE.md's project-specific red lines) are **denied by default** — do them only with explicit upfront user authorization (this run's instructions or the project CLAUDE.md's `{{AUTHORIZED_REDLINE_EXCEPTIONS}}`); if unauthorized, skip that item and mark "authorization needed" in the report. Only stop when the device is physically disconnected (after one self-recovery attempt) or when the requirement has an ambiguity you cannot resolve on your own. Rules, lookup priority, the Key+Semantics dual-standard, hot reload tiers, and the two teardown steps all align with the `flutter-autonomous` skill; this command only drives the flow. **Committing is not a default action** — handle it per the user's commit policy (see Step 5).

---

## Step 1: Define acceptance criteria (confirm them yourself, don't wait)

Expand into 3~8 assertable acceptance conditions: each one is "action (find `Key`/label → do what) → expected"; list the `Key`+`Semantics` widgets to add; list the files to change; mark for each which layer verifies it (offline fixture / device / log evidence).

If the requirement itself has an ambiguity you cannot resolve on your own (don't know which page to jump to, UI unclear, platform unclear) → **stop, explain the ambiguous points, and wait for my confirmation**.

---

## Step 2: Implement

- Write the Dart implementation, following all conventions in the project `CLAUDE.md`.
- Add `key: const Key('xxx')` to key widgets (used by Patrol) + `Semantics(label:)` (used for element-driven interaction); wrap custom gesture widgets explicitly with `Semantics(label+button:true)`.
- Add the accompanying tests in sync: pure logic that can be locked offline goes in `test/.../xxx_test.dart` (fixture/mock); interaction/navigation/display goes in `integration_test/<feature>_test.dart` (turn each acceptance condition into a Patrol case, by `Key`).
- Code changes rely on `--pid-file` + `USR1` (method-body hot reload) / `USR2` (init·main·route hot restart) — don't cold-start at the drop of a hat.

---

## Step 3: Four-layer verification (fixed order, ≤5 rounds of self-fixing)

Each round:

```bash
flutter analyze                       # ① continue only at zero warnings
flutter test                          # ② offline fixture layer (seconds, no device; skip if no test/) — green first, then go to device
mobilecli devices                     # ③ device discovery (don't hardcode id; iOS defaults to simulator, see references/ios.md)
mobilecli apps foreground --device <id>   # before entering the device, confirm foreground = target package, to prevent cross-talk
patrol test -t integration_test/<feature>_test.dart --device <deviceId>   # ④ device layer: Patrol by Key
```

- Offline layer (②) failure = pure logic bug, fix the implementation per category C below, **do not weaken assertions**, only go to device once offline is fully green.
- Devices all empty: if it's still empty after one round of environment bootstrap self-recovery = offline, stop and report.
- **Failure categories** (assertion failure = change implementation, not the test):
  - A compile failure → read the full analyze output and fix, back to round start
  - B `found 0 widgets` → check Key spelling / conditional rendering / whether `.scrollTo()` is needed; can't be listed = back to the code to add `Semantics`
  - C assertion failure → logic bug, fix the implementation, don't lower the bar
  - D crash/timeout → `mobilecli device crashes list/get` to read the first `package:<your_app>/` line of the stack
  - E install/disconnect → `mobilecli devices` retry once, stop if it still fails
- **Still not passing on round 5**: stop this feature and output a stuck report (failure symptom / verbatim error / directions already tried / suspected root cause).

---

## Step 4: Screenshot verification

`mobilecli screenshot --device <id> -o <out>` → Read to self-check layout/truncation/color/empty-state/Loading. Visual issues just need code changes, no need to rerun Patrol (unless the visual fix touched functional logic).

---

## Step 5: Teardown + (per commit policy) handle the commit

```bash
# Two teardown steps with verification (kill flutter run ≠ closing the App) — always do this step
kill "$(cat <PID_FILE>)" 2>/dev/null
mobilecli apps terminate --device <id> <packageName>
mobilecli apps foreground --device <id>            # verify it's actually closed
```

**Committing is not a default action of this flow**: handle it per the user's commit policy (ask up front before starting / see the `{{COMMIT_POLICY}}` in the project `CLAUDE.md`) — commit incrementally / commit everything together once done / don't commit (the human commits themselves) / other. **Do not auto-commit by default.** If the policy is to commit, the conventions follow the user's global / project `CLAUDE.md` (precise `git add`, not `git add .`; conventional message; for text containing backticks/`$`/`!` use single quotes or `-F`; never add an AI attribution footer; whether to push depends on the policy), and after committing run `git log -1 --stat` to verify HEAD actually moved.

---

## Step 6: Report

```
## ✅ Feature: <feature name>

Acceptance conditions:
- [x] Condition 1
- [x] Condition 2

Changes: lib/xxx.dart, integration_test/xxx_test.dart, test/xxx_test.dart
Verification: analyze ✅ / flutter test ✅(N) / patrol ✅(N) / screenshot ✅
Commit: (if committed per the policy) <hash> feat: xxx (HEAD verified) / otherwise note "not committed per policy"
Screenshots: (key screenshots)
Remaining: none / <specifics>
```

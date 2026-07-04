---
description: All-night autonomous mode — run the full ship flow over each task in order, skip-and-continue on stuck/ambiguous, emit a summary table at the end (commit per the user's policy, no push by default)
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
argument-hint: [task list (one task per line)]
---

**All-night autonomous task list:**

$ARGUMENTS

Rules, locator priority, the Key+Semantics dual annotation, failure classification, and the two-step teardown all align with the `flutter-autonomous` skill; **committing is not a default action** — handle it per the user's commit policy. This command is the batch orchestration of `/ship`; it only fills in the "all-night scheduling" differences.

---

## Scheduling rules

1. **Strictly in order**, one at a time, **no parallelism** (parallel runs against the same codebase collide on files, contend for the device, and cross-talk).
2. **Each task runs the full `/ship` flow**: set the criteria → implement (+Key+Semantics+matching tests) → four-layer verification → screenshot verification → (handle committing per the user's commit policy, no auto-commit by default).
3. **Stuck ceiling**: ≤5 self-repair rounds per task. Still failing on the 5th round → mark ⚠️, record the directions already tried, **skip and continue to the next**.
4. **On ambiguity**: the task description itself has ambiguity you cannot resolve on your own (unsure which page to jump to / unclear UI / unclear platform) → mark ⚠️, **skip and continue to the next**, don't silently decide for me. A task requiring an **unauthorized red-line operation** (real money / secrets / irreversible) is likewise marked ⚠️ and skipped, noting in the report what authorization is needed — **never hang waiting for my reply**.
5. **Device offline**: if environment self-bootstrap/recovery + one reconnect still fails → **stop all remaining tasks**, emit a "device offline" report (any commits already made are kept).
6. **Commit per the user's commit policy** (clarify up front: commit-as-you-go / one at the end / don't commit / other); **no push** by default, wait for human review in the morning.

---

## Per-task execution flow

```
For task N:
  1. Set acceptance criteria (confirm yourself, don't wait on anyone); ambiguous → mark ⚠️ skip
  2. Implement + matching tests (add Key+Semantics to key widgets; wrap custom gesture widgets explicitly in Semantics)
  3. flutter analyze (zero warnings)
  4. flutter test (offline fixture layer, sub-second no device; skip if no test/) — offline-layer failure = logic bug, fix the implementation, don't weaken the assertion; go green first, then move to device
  5. mobilecli devices (device discovery, don't hardcode the id) → apps foreground confirm foreground = target package
  6. patrol test -t integration_test/<feature>_test.dart --device <id> (iOS default simulator, see references/ios.md)
     ├── pass → screenshot verification → two-step teardown (kill host + apps terminate) and recheck → (handle committing per the commit policy) → record → task N+1
     └── fail → failure classification (A compile / B found 0 / C assertion: fix implementation not test / D crash: read the stack trace / E disconnect: retry once) fix → back to step 3 (≤5 rounds)
                still failing on 5th round → mark ⚠️ record directions tried → task N+1
```

> Commit per the user's policy (as-you-go / at the end / don't commit); **no auto-commit by default**. If committing, follow the user's global/project `CLAUDE.md` for conventions (precise `add`, no `git add .`; single quotes or `-F` for messages with backticks/`$`/`!`; **never add AI attribution**), then `git log -1 --stat` to recheck HEAD. Run the two App-close steps and recheck at the end of every task to avoid cross-talk with the next task.

---

## After all-night ends: summary report

```
# All-night task summary report
Completion time: <time>
Device: <id/platform freshly obtained from mobilecli devices>

## Task results
| # | Feature | Status | Commit |
|---|---------|--------|--------|
| 1 | feature name | ✅ done | abc1234 |
| 2 | feature name | ⚠️ skipped (5 rounds failed / ambiguous / authorization needed) | — |
| 3 | feature name | ✅ done | def5678 |

## Detailed report

### Task 1: <feature name> ✅
Acceptance criteria:
- [x] criterion 1
- [x] criterion 2
Changes: xxx.dart, xxx_test.dart
Verification: analyze ✅ / flutter test ✅(N) / patrol ✅(N)
Commit: abc1234 feat: xxx (HEAD rechecked)
Screenshots: (key screenshots)

### Task 2: <feature name> ⚠️ skipped
Reason: <5-round failure symptom + verbatim error / ambiguity note>
Tried: <brief directions>
Suggestion: <how to handle next>

---

## Points needing human decision
1. <specific question>
2. (if none, write: none)
```

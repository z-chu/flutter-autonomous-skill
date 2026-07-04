# Scaling and Unattended Operation

> This doc builds on the keystone (`../SKILL.md`): closed-loop methodology, the four red lines of environment self-bootstrapping, element-driven first, the Key+Semantics dual labeling, the four verification layers, `--pid-file`+`USR1/USR2`, `kill≠force-stop`, commit conventions — all there. **Here we only cover "scaling a single loop into multiple parallel ones, then into unattended operation."**
>
> One-line throughline: the only two things that are irreplaceable for you are **① translating requirements into assertable acceptance criteria** (more valuable the more you practice) and **② reviewing conclusions and steering direction**; everything else — "run, tap, look, fix" — is offloaded onto AI's time. Scaling = offloading multiple loops at once + offloading while you sleep.
>
> Project-specific values (package name/device/dart-define/red lines) are always read from the project root `CLAUDE.md`; **this doc hard-codes not a single concrete value**.

---

## 1. Trust ladder: watch once or twice first, then let it fly

**Don't go straight to all-night autopilot** — you won't trust it, and you won't be able to catch it when it goes off the rails. Watch it once or twice to learn its temperament (how it unfolds acceptance criteria, how it localizes failures, which round it tends to fixate on a dead end), and trust builds naturally. Four escalating levels:

| Level | What you do | What AI does | Signal: ready to level up |
|---|---|---|---|
| **L1 Loop observer** | `/spec` to unfold acceptance criteria + **manual confirmation** + **watch the whole way through** | Implement → run verification → self-fix, with you watching every step | You understand what the loop looks like: how it does `dump ui`, how it reads failures, which round it converges |
| **L2 Hands-off verification** | `/ship` all the way to commit, **review only the final report** | Implement → dual-platform verification → self-fix (≤5 rounds) → commit (no push) | The "acceptance comparison table" in several consecutive reports matches the conclusions you ran yourself; you start trusting it |
| **L3 Unattended** | Drop a task list before bed / `/schedule` a timed run, **harvest in the morning** | Run `/ship` on each item in the list one by one, skip and flag when stuck, accumulate a batch of reports | Your acceptance criteria are written accurately enough (it rarely stops on ambiguity), and the guardrails are in place (see §4) |
| **L4 Process operator** | Distill the working master template (`CLAUDE.md` constitution + `.claude/commands/` + permission allowlist + hooks) **into a team template** | Others copy and use it as-is | You shift from "writing fast" to "designing how others write fast" — this is the position with the highest leverage |

**Iron rule for leveling up**: at each level, **stably reproduce success** at the level below before jumping up. L1→L2 is about "the report is trustworthy," L2→L3 is about "acceptance criteria accurate enough that it no longer asks you frequently." The cost of skipping a level: you don't trust it → you still have to re-verify an entire night's output line by line, a wasted run.

> Learning point: **Watch the loop once (L1), then go hands-off (L2), and only then scale (L3/L4).** Trust is earned by watching, not by gambling.

---

## 2. Three parallel postures + how to choose

The prerequisite for parallelism is that **tasks are independent of each other and each can be independently verified all-green**. For dependent tasks, do the foundation serially first, then build the upper layers in parallel.

### Posture one: multiple git worktrees + multiple terminals (simplest and most direct)

Open an independent worktree per feature (independent working tree + independent branch, no cross-contamination), open a Claude Code window for each, and each runs its own `/ship`. You're like "managing multiple interns," each with an isolated workstation.

```bash
# Run in the main repo root; name paths/branches by feature, don't hard-code
git worktree add ../app-feat-x -b feat/x
git worktree add ../app-feat-y -b feat/y
# Enter ../app-feat-x and ../app-feat-y separately, open claude in each, run /ship in each
```

- **Pros**: most thorough isolation (each with independent build artifacts, independent `flutter run` host), no fighting over files.
- **Device note**: multiple `flutter run` instances **sharing the same device** will fight each other — `--pid-file` must **append a project/branch suffix** to avoid collision (the keystone already stresses this), and don't hot reload two sets on the same device at once. Ideally **one worktree per device/simulator**; if you don't have enough devices, stagger the runs, or run all on simulators (fast, can open multiple).
- **Teardown**: when each worktree finishes, run the keystone's two teardown steps (stop host + `apps terminate`) and verify; don't leave a pile of co-existing Apps cross-talking on the device. When done with a worktree, clean it up with `git worktree remove <path>`.

### Posture two: single-session subagents in parallel in isolated worktrees (one-sentence scheduling)

Just tell the AI in one sentence, and it dispatches multiple subagents to work on multiple independent features simultaneously **in their own isolated worktrees**, each subagent running to dual-platform verification all-green and committing on its own, with the main session finally aggregating the multiple reports. Suited for "I can't be bothered to open multiple windows, but I want to push several things at once."

> Using mutually isolated worktrees, implement the following N independent features in parallel, each self-verifying to dual-platform all-green (≤5 rounds of self-fix) before committing on its own (no push), finally aggregating each one's acceptance comparison table + changes + screenshots + commit hash:
> 1) ... 2) ... 3) ...

- **Difference from posture one**: you issue only one instruction, scheduling is handed to the main session; isolation still relies on worktrees.
- **Applicable**: 2~4 **truly independent** features. Once they share files/dependencies, subagents collide with each other and it ends up slower — in that case fall back to serial or break into smaller pieces.

### Posture three: Workflow orchestration (advanced, heavy, token-hungry, requires explicit opt-in)

Only bring this out for scaling scenarios that need "**fan out a large number of agents + adversarial verification + synthesis**" — one-off auditing/migrating an entire module, large refactors spanning multiple modules. It fans out multiple agents to divide the work, cross-checks with adversarial verification, then synthesizes into a conclusion.

- **Cost**: heavy, significantly token-hungry, large coordination overhead. **It won't trigger by default**: you have to **explicitly say "use workflow"** or turn on ultracode for me to bring it out.
- **Don't abuse it**: for daily 1~3 features, posture one/two is enough; don't use a sledgehammer to crack a nut.

### How to choose (one line)

| Task scale | Which to pick |
|---|---|
| **1 feature** | Just `/ship`, no parallelism |
| **2~4 mutually independent features** | Posture two (subagents + isolated worktrees); want more thorough isolation / to watch each → posture one |
| **Cross-module large refactor / whole-module audit·migration** | Posture three (explicitly turn on workflow) |

---

## 3. Unattended toolbox

Hand off "repeated triggering, watching progress, topping up the allowlist" too — only then is L3 truly unattended.

| Tool | What it does | How to use / notes |
|---|---|---|
| **`/schedule`** | Run a pipeline on a schedule (cron) — auto-run the list once at a set time every night | Set it once, it fires automatically at the time; pair with the "all-night task list" template in §5. One-off "run once at 3 AM tonight" also works |
| **`/loop`** | Poll on an interval — watch CI, watch some state until a condition is met | E.g. "check CI every 5 minutes, notify when green"; **don't use loop for one-off tasks** |
| **`/fewer-permission-prompts`** | Scan operation history, automatically top up high-frequency read-only commands into the project `.claude/settings.json` allowlist | Run this when you're tired of the popups after a long run; say goodbye to repeated flutter/dart/patrol/git confirmations |
| **`Shift+Tab` → accept-edits** | Switch to "auto-accept file changes" mode | Reduces interruptions during all-night unattended runs; **only switch when you trust the task's scope**, don't leave it on globally for long |
| **`--dangerously-skip-permissions`** | Skip **all** confirmations | ⚠️ **Use only in isolated environments**: clean container / one-off worktree + **test data**. **Never** run bare on the main project that contains keys or can write to production over the network (see §4) |

> Suggested order: first use the **allowlist + hooks** (format/analyze self-check, see keystone and templates) to drive daily popups close to zero, then consider accept-edits; `--dangerously-skip-permissions` is the last resort, and must be paired with an isolated environment.

---

## 4. Safety guardrails: let go but don't crash

Unattended operation amplifies **output**, and also amplifies **crashes**. None of the four guardrails can be skipped:

1. **Commit only, don't push** (default). Auto-accumulate commits all night, **push only after you review in the morning**. Auto-merge/auto-push needs caution — a merge no one looks at most easily drags dirty things in. This is also an extension of the keystone's commit conventions.
2. **Run all-night with mock / test accounts, don't connect to real backends and write to production**. **Physically isolate** the verification environment from production data. Anything involving real-money operations / secrets & credentials / irreversible destruction = the keystone's red lines (plus project-specific red lines from the project CLAUDE.md): **denied by default, allowed only with your explicit upfront authorization (scope stated)**; an unattended run that hits an unauthorized red-line operation skips it and marks "authorization needed" — it never waits, and gets no exemption.
3. **Always demand evidence; without evidence it doesn't count as done**. Each report must include: **acceptance comparison table (each item ✅/❌) + key screenshots + list of changed files + commit hash**. This is the hardening of "don't verify, don't report done" under scaling — in the morning you harvest based on **evidence**, not on "it said it's done." A failure stuck at round 5 must also be flagged honestly, don't hide it.
4. **Verification also goes into CI (double insurance)**. Put Patrol cases into CI to run as well — local all-green + CI all-green, and only then does unattended output withstand a second pair of eyes. The prerequisite for pairing `--dangerously-skip-permissions` with an isolated environment (test data, clean worktree) also belongs to this guardrail: **isolation is the entry ticket for letting go**.

> One line: **a "done" without evidence doesn't count as done; a "letting go" without isolation isn't letting go, it's gambling.**

---

## 5. Prompt templates (fill in the blanks, all placeholders, no project values)

Replace every `<...>` in the templates below with your actual requirements; package name/device/red lines are provided by the project `CLAUDE.md`, not written in the templates.

```text
# New feature (fully automatic)
/ship <feature>. Done criteria: after <operation> it should <expected>; edge cases: <on abnormal input/network failure/empty data it should ...>.
Follow CLAUDE.md conventions (add Key+Semantics to interactable/assertable controls, accompanying Patrol cases), dual-platform verify all-green before committing.
```

```text
# Fix a bug (with repro + regression case)
/ship fix: <symptom>. Repro steps: <1> → <2> → <3>, expected <X> actual <Y>.
Localize the root cause first, fix the implementation (not modify tests to lower the bar); after fixing write one Patrol regression case to lock it down by Key, dual-platform verify passing before committing.
```

```text
# Verify existing changes only (no new features)
/verify focus on verifying <feature/page>, both iOS + Android must pass.
Treat failures as "logic bug, fix the implementation," ≤5 rounds of self-fix; produce an acceptance comparison table + screenshots + points still in doubt.
```

```text
# Visual gatekeeping (element-driven + screenshots)
Get it running, use dump ui to navigate to <page> (tap by label, no blind-tap), screenshot it for me to look at:
<is the layout misaligned / is the text contrast sufficient in dark mode / is <some element> in the expected position>.
Also report any RenderFlex overflow and the like.
```

```text
# Parallel delivery (isolated worktrees)
Using mutually isolated worktrees, do the following several mutually independent features in parallel, each dual-platform verifying to all-green (≤5 rounds of self-fix) before committing on its own (no push), finally aggregating each one's acceptance comparison + changes + screenshots + commit hash:
1) <feature A> 2) <feature B> 3) <feature C>
```

```text
# All-night task list (unattended)
Tonight, autonomously complete the following tasks in order, each at /ship level (implement → dual-platform verify → ≤5 rounds of self-fix → commit, no push).
Use mock/test data, never connect to production, don't touch real-money operations/secrets/irreversible operations.
If any task maxes out 5 rounds of self-fix or hits requirement ambiguity, skip it and flag the reason in the report, continue to the next.
In the morning give me an aggregate: each task's acceptance comparison table + changed files + key screenshots + commit hash + leftover/stuck items.
- [ ] <task 1>
- [ ] <task 2>
- [ ] <task 3>
```

> The highest-return line in a template is always the "done criteria" sentence — write clearly "what done looks like + how under abnormal conditions," and it saves you an entire night of back-and-forth. This is that "only irreplaceable" thing from §1.

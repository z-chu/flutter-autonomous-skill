# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`Semantics(identifier:)` in the code contract, and in the matcher.** The
  contract taught `Semantics(label:)` only — but a label is human-readable
  visible copy, so rewording a string or switching locale breaks anything
  locating by it, which a multi-language app does routinely. `identifier`
  (Flutter 3.19+) is the stable id meant for automation, mapping to Android's
  resource-id and iOS's accessibilityIdentifier. `dump ui` already returned the
  field and `tap-by-label.sh` was ignoring it; it now matches on
  `identifier / label / text / name`, identifier first, while still displaying
  the label so a human scanning `--dump-only` still recognises the row. Reuse
  the name you gave `Key` — one naming feeds both Patrol and element-driven
  interaction. It also enters the locator priority list, second only to `Key`.
  (Prompted by reviewing Maestro, which recommends the same field; Maestro
  itself stays out — living outside the Flutter runtime, it cannot see `Key`s
  at all.)

- **A worked example of expanding acceptance criteria**, in the autonomous loop
  section. Step one of the loop had always said "self-expand into 3–8 assertable
  items, tagged by layer", but never showed what that looks like — and it is the
  step every later decision hangs on. The example ships with its own test: if you
  can't tag an item with a layer, it isn't assertable yet, so rewrite it before
  starting.
- **A rule for how many platforms to run.** The description, `/ship`, `/verify`
  and the scaling templates all asked for "both platforms green", while the loop
  diagram was single-device and nothing said when both are actually required.
  What the project ships decides first — a single-platform project runs that
  platform only, rather than chasing parity onto one it doesn't ship. Past that,
  the change decides: both when platform channels/native plugins/permission
  dialogs/IME/safe areas/back gestures/font-metric-sensitive layout are involved;
  otherwise one, stated as such in the report. Simulator first where there is
  one — and single-platform green is never written up as both-platform green.
- **Prerequisite state (login, wallet, identity, seed data) is now classified as
  "only a human can give it"**, alongside the GUI-only permission blockers it
  already sat next to in spirit. Nothing can be verified behind a login wall, and
  it isn't something the run can install its way past. The order matters: don't
  lead with the question — the device is usually already logged in, so launch and
  look, then try to route around it (deeplink to the page under test, or a
  debug-only hook that sets state via VM Service `evaluate`). Only when that
  fails does it stop, and it stops saying what it's stuck on, so the user can
  hand over a test account, tap through it themselves, or authorize registering
  one. It is a runtime blocker, not project configuration — the skill asks the
  person in front of it rather than requiring anything to be set up in advance.

- **`tools/check-mirror.sh`**, a maintainer check that the English files haven't
  quietly fallen behind `zh/`. "Sync it afterwards" was an honor-system rule, and
  it had already failed for two releases without anything in the repo looking
  wrong. The structural mode pairs every file and compares four things —
  heading counts, code-block counts, line counts (15% tolerance, so a paragraph
  dropped inside a section that kept all its headings still trips it), and
  reference integrity: a `references/foo.md` written in `SKILL.md` must exist on
  that same side, because a pointer into nothing is a dead end the run only
  discovers mid-task, and the other side's file existing is exactly what hides
  it. `--diff <ref>` fails when a branch touches one side alone. It lives outside
  `skills/` on purpose — everything under there ships to every user, and a
  maintainer tool is dead weight in every install.

- **A "silent failure" list for device input.** The backend guarantees the event
  was dispatched, not that Flutter received it — and when it doesn't, the exit
  code is still 0. `io swipe` is the usual offender (Flutter's scroll gestures
  are sensitive to a synthesized event's duration and step; the screen simply
  doesn't move), alongside synthesized long-presses and taps that land in the
  blank area of a container wrapping the target. The rule is now explicit:
  confirm with outside evidence — dump again and compare an anchor's `rect.y`,
  or diff screenshots — and after two failed attempts change route rather than
  burning rounds on the same command. This was already covered in spirit by
  "don't treat performing an action as achieving the result"; naming the
  commands it actually happens with is what makes it checkable.

- **A codegen tier in the hot-reload table.** The table jumped from method
  bodies to native code and never mentioned the most common Flutter case in
  between: `.arb`/l10n strings, freezed and json_serializable annotations,
  drift schemas. A bare USR1 shows the stale generated output, which reads
  exactly like "my change didn't take" — and sends you off editing code that
  was already correct. Run the generator first, then USR2.

- **What a simulator cannot verify.** "Simulator first" is good advice that
  quietly breaks for a specific class of work: screenshot protection and secure
  layers (a simulator captures fine, which looks identical to the feature not
  working), real performance and jank, biometrics, push, camera and sensors,
  attestation SDKs, real network conditions. Its green there is a fake green, so
  that class now skips the simulator tier and goes straight to a real device.

- **A reset before every acceptance item.** State left behind by the previous
  item becomes the next one's starting point — parked in a bottom sheet, a
  filter still applied — and the drift compounds while the report looks fine,
  because every screenshot has content; it's just the wrong page. Three steps
  (`apps terminate` → `apps launch` → `dump ui` to confirm the starting point)
  cost seconds and buy off an entire item being silently invalid. Unattended
  runs are where this matters most, and where nobody is watching to catch it.

- **`adb shell` does not go through the phone's VPN/proxy** (`references/android.md`).
  `adb shell curl/ping` uses the device's raw network stack and bypasses any TUN
  a VPN or proxy app has set up, so using it to decide whether the app can reach
  a domain can return the exact opposite of what the app sees. Reachability is
  now judged from the app's own evidence (request outcomes in the logs, state via
  the VM Service); `adb shell` is for the physical link only. Getting it backwards
  costs a round spent fixing a network bug that doesn't exist.

- **`references/cross-screen-verification.md`**, for the properties one screenful
  cannot show. `dump ui` returns the viewport, not the list — so pagination order,
  no-duplicates across page boundaries, "does it actually reach the end" and
  timeline grouping are undecidable from any single dump, and undecidable by eye
  at all, because the failure sits hundreds of items down where nobody scrolls by
  hand. The method is always the same shape: collect one dump per scroll step to
  disk, stitch the rounds into one global sequence, assert on that sequence in
  code. Three traps come with it, each worth a wasted round: **calibrate the ruler
  before trusting the verdict** — a label filter that misses one row variant drops
  that variant's group header too and manufactures impossible-looking ordering
  violations, so when the verdict says "anomaly", verify the judging method before
  investigating the subject; **"the screen didn't move" means three different
  things** — the gesture was swallowed, the list is genuinely at the end (Android's
  default ClampingScrollPhysics gives zero displacement there, by design), or a
  load is hung — and all three are byte-identical in `dump ui`, which makes the
  paging footer's states a code defect when they aren't distinguishable
  (a bare spinner and `SizedBox.shrink()` are the same nothing in the semantics
  tree; give each state a stable `identifier`); and **keep the raw data out of
  context** — forty dumps are judged in the shell, and only the verdict is read
  back.

- **Disable every input method before typing, and read the text back after**
  (`references/android.md` §4.4). The IME panel covers the element under test
  *and* puts its own keys into `dump ui`, so locating by label picks the keyboard
  instead of the app's widget. Disabling the default one is not enough: the system
  hands over to voice input and you get a panel anyway, so the disable list comes
  from `ime list -a -s`. Typing then joins the "silent failure" list next to
  `io swipe` — exit code 0 from `input text` says the event was dispatched, not
  that the characters landed — so the field's `text` is read back and compared
  character for character, and a mismatch resolves to one of three causes (focus
  never landed, the panel intercepted it, or it isn't a system text field at all).
  Restoring at teardown records two independent facts, which were enabled and
  which was the default, because mixing them up leaves the user's phone with a
  silently swapped keyboard.

- **The deeplink shortcut, applied to state depth rather than navigation depth.**
  When the thing under test only appears deep in — page 40 of a list, after a
  countdown, in an error state — driving the UI there costs minutes per pass and
  you rarely need only one pass. A debug-only hook that puts the app in that state
  in one step is the same move as jumping straight to a page with a deeplink, and
  on a long list it is the single biggest win available.

- **After a fix, re-run the items that were already passing.** A change to scale,
  timing or frequency — page size, timeout, poll interval, concurrency, batch size
  — moves every race that used to be won by luck: shrinking a page from one large
  remote batch to fifteen items is enough to make a pre-existing race fire on
  every run, in a path that had been green all along. The item you fixed is the
  one you're watching; the regression lands somewhere you aren't.

- **One distinctive prefix on temporary diagnostic logs** (`[paging-probe]`).
  It is what you grep to read them out of a logcat full of third-party noise, and
  — the part that matters — what you grep to prove every one of them is gone
  before committing. Print the values that decide which branch ran, not "got
  here": one well-chosen line usually ends an investigation that screenshots and
  guessing were going to drag through several hot-reload rounds.

### Fixed

- **`npx skills add` found no skill at all.** The frontmatter `description:` was
  an unquoted YAML scalar containing `": "` (in `Use for: running the app…`),
  which YAML reads as a nested mapping — so the skills CLI skipped both
  `SKILL.md` files with a parse error and reported "No valid skills found". That
  is install channel A, the one the README lists first. Both descriptions are now
  single-quoted. Claude Code's own loader was more forgiving and had always read
  the file, which is why this went unnoticed: the channel that broke was the one
  the maintainer never used.

- **The build-wait loop could spin forever.** It waited on the vmservice file or
  a short list of grep patterns, so any failure outside that list (CocoaPods,
  signing, `No supported devices`) left it polling until the harness killed it —
  and the `<output>` it grepped never existed, since backgrounding the run left
  no log file to read. The loop now has all three exits, and the launch keeps
  output you can `tail`.
  - Only "the process exited" counts as failure. The deadline is an alarm clock,
    not a verdict: a cold checkout, a large project, a slow network or a CI
    container can all legitimately build for half an hour, and a run that reads
    its own alarm as a failed build and starts over with `flutter clean` turns
    one slow build into two. Still alive with a growing log means keep waiting.

- **`tap-by-label.sh` could tap nothing at all, and report success.** Two bugs,
  both of which surface on ordinary Flutter screens:
  - The TSV put the label first, unescaped. Semantics merging routinely produces
    multi-line labels (a wallet row is `"Wallet 2\naddress\n$0"`), so one match
    became several lines: the count inflated, `sed -n Np` picked a fragment with
    no tabs, the coordinates read back empty, and `io tap ","` went out — while
    the script printed "tapped" and exited 0. Coordinates now come first, the
    label is whitespace-folded and emitted last through `@tsv`, and a coordinate
    check refuses to tap on anything malformed instead of failing silently.
  - Matches came back in document order, and jq's `..` is pre-order, so an
    ancestor — whose merged label naturally contains the substring — always
    ranked above the leaf. `--index 0` therefore tended to tap the row or card
    wrapping the target, landing in its blank area: the exact "tapped it,
    nothing happened" symptom. Matches are now sorted by rect area ascending,
    so the default is the smallest — the leaf you meant — and `--dump-only`
    prints the areas so a wrong pick is visible before you tap.

### Changed

- **The loop's analyze gate scopes the command instead of loosening the bar.**
  `flutter analyze (zero warnings)` was a clean pass/fail that nobody could meet
  in practice: run over the whole repo it drowns in third-party code under
  `build/`. Narrowing the *verdict* to "count the errors in the dirs you touched"
  would have fixed the noise by trading away the one thing that made the step
  decidable — whether it is done. The gate is now `flutter analyze lib test
  integration_test` at zero errors: same silence about third-party code, and the
  bound stays binary.
- **English is now what ships; Chinese moved to `zh/`.** The layout had it
  backwards for an open-source project: `skills/flutter-autonomous/SKILL.md` was
  Chinese and the English mirror sat one directory down in `en/`, so the file
  Claude loads on an English user's machine — and everything `references/` and
  `templates/` install — was the translated copy, always the side at risk of
  lagging. The two are swapped: the skill root is English, the Chinese copy is
  `zh/`. Editing order is unchanged (Chinese first, then sync), only which side
  ships. Two things fall out of the swap for free: `SKILL.md`'s relative links to
  `scripts/` now resolve from the file that actually gets loaded, and
  `tools/check-mirror.sh` guards the direction that matters.
- **The three shipped shell scripts speak English.** `bootstrap.sh`,
  `setup-project.sh` and `tap-by-label.sh` printed every diagnostic, hint and
  summary row in Chinese — they are the first thing a new user sees after the
  one-line install, and they were the loudest remaining Chinese surface. Comments
  and output are translated; not one line of logic changed. Scripts stay
  single-language by the existing convention (code is not mirrored), so there is
  no `zh/` copy of them.
- **`tools/check-mirror.sh` runs in the new direction, in English.** It now
  pairs `zh/**` against the skill root rather than the root against `en/`, and
  since the README tells PR authors to run it before opening a PR, its own output
  is English too.

- **"Re-check" is now a leading word, not eight phrasings of the same idea.** One
  concept — prove the result with an independent command instead of inferring it
  from having run the action — was spelled out at eight sites in five different
  ways: "re-verify with an independent command", "confirm with outside evidence",
  "compare and confirm", "don't treat 'I ran kill' as 'the app is closed'". It is
  defined once now, beside the green zone it sits next to in spirit, and every
  site reuses the word. The word does the anchoring the restatements were trying
  to do, in one token: 6 uses before, 23 after, while the document got shorter.
  Its boundary is stated with it, because two words were quietly competing for
  the same job: a re-check takes machine-decidable evidence (a dump comparison,
  the foreground package, a return code), while eyeballing a screenshot for how
  something looks is *screenshot verification* — both required, neither a
  substitute for the other. Everything that verifies state now says "re-check";
  everything that judges appearance still says "verify".

- **The Rules checklist points instead of restating.** It had drifted into a
  compressed rewrite of the body, which meant every behaviour change had to be
  written twice per language — the last batch of five changes touched twenty
  edit sites for five ideas. Each rule is now its bar plus a section reference,
  so the mechanism has one home and the checklist can be scanned rather than
  read.

- **The anti-pattern list went from nine prohibitions to two.** Eight of the nine
  were the exact inverse of an Always rule already stated positively above, so
  they paid tokens to drag the forbidden behaviour into context and say nothing
  new. What remains is the pair with no positive form to point at: reporting a
  result without re-checking it, and passing offline-green off as UI-verified.
  Elsewhere the same edit ran through the prose — "never write a device id into
  any file" became "a device id lives only inside this run", "don't chase parity"
  became "run the platforms the project actually ships". The four red lines keep
  their prohibitions: a hard guardrail is the one case that earns one.

### Removed

- **The reassurance that a missing memory mechanism is fine.** "Re-detecting
  takes seconds; don't require the user to configure anything" was written for
  the reader, not the agent: the rationale changes no behaviour, and the one
  instruction buried in it — don't ask for configuration — is already stated
  twice above it ("project-specific values are never hardcoded... it runs
  without them", "auto-detect, don't ask, don't hardcode").

- **The project `CLAUDE.md` template, and with it the idea that this skill needs
  configuring at all.** The author — its heaviest user — had never once filled it
  in across countless runs, which is the tell: it asked for things nobody should
  have to supply. Most of it was derivable (the installer auto-filled four of the
  ids itself, proof they didn't need a slot); the device section said "never
  hardcode this" while offering a field to hardcode it in; the
  Definition-of-Done section restated the skill's own completion bar, where it
  could only drift out of agreement. What was genuinely human knowledge — log
  anchors, toolchain constraints, project red lines, commit policy — is better
  said in the conversation, and written into your own `CLAUDE.md` only if you
  want it to persist.
  - **Deleting it costs nothing in safety, because red lines are deny-by-default.**
    With nothing written down, all four stay fully in force and unauthorized
    operations are skipped; configuration only ever *added* project-specific red
    lines or *unlocked* exceptions. The absence of a config file can make a run
    more conservative, never less. The overnight case is already covered where
    it actually belongs — the unattended prompt template in `references/scaling.md`
    states the constraints inline, at the moment you set the run up.
  - Keeping it was not neutral: three places in `SKILL.md` had already drifted
    into telling the model to read package ids and even the device id from
    `CLAUDE.md`, contradicting §1's "auto-detect, never hardcode" — and the
    opening paragraph, the source of the contradiction, said it too. All are
    fixed, and the placeholder tokens they reached for no longer exist.
  - `setup-project.sh` drops from 255 to 147 lines and **now writes only into
    `.claude/`** — it never touches your project root. Nothing needs configuring
    before the first run.
- **The English mirror is back in sync**, a full version behind since 1.1.0. It
  was missing §0 (when not to use the skill), the whole VM Service path and
  `references/vm-service.md`, the device-first verification layering, the widget
  test and golden/a11y layers of the offline reference, the Android log-window,
  determinism-switch and performance-metric sections, and the iOS simulator
  determinism switches. Its `description` also still advertised offline unit
  tests — the exact triggering the Chinese version had deliberately dropped.
- **"Offline-green is not UI-verified" now appears twice instead of five times.**
  Repetition past the mechanism and the checklist was buying nothing; the space
  went to the three gaps above.

## [1.1.0] - 2026-08-16

### Added

- **A GitHub Releases fallback when npm is blocked.** Reported from the field: a
  corporate gateway intercepted the npm registry while GitHub stayed open, and
  the skill's only documented fallbacks (`npx`, which hits the same registry,
  and building from source, which needs a Go toolchain) were both dead ends — so
  the run stopped for a human when it did not have to.
  - `scripts/bootstrap.sh` now falls back to GitHub Releases for mobilecli and
    jq, handling both macOS traps (missing exec bit, Gatekeeper quarantine).
    It costs an unaffected machine nothing — the fallback only runs once the
    normal channel has failed.
  - A two-line rule in §2: classify a blocker as a **channel** problem (still
    green zone — switch routes and continue) or a **permission** problem (a
    genuine stop, since only a human can grant it in a GUI). Getting it
    backwards costs either a needless stop or a burnt round of self-repair.
  - `references/restricted-network.md` holds the rest behind a pointer, kept to
    the handful of things an agent can't guess (npx shares the registry;
    Gatekeeper quarantine; PATH not persisting across Bash calls; which tools
    GitHub can't rescue). Scope is a blocked package source only — Xcode, the
    Android SDK and vendor distribution domains are deliberately out of scope.
- **`scripts/bootstrap.sh` now checks jq**, a hard dependency of
  `scripts/tap-by-label.sh` that was previously never verified.
- Two iOS gotchas: `agent install` backgrounds the app under test (relaunch
  before dumping), and `xcrun simctl privacy grant/revoke` commonly fails with
  `Operation not permitted` (reinstall the app or toggle the switch in Settings).
- A Flutter interaction limit: a WDA-synthesised `io longpress` may not register
  on the Flutter side; prefer making the gesture a tappable control with
  `Semantics` instead of fighting it.

### Changed

- **Red lines are now deny-by-default.** Spending real money, touching secrets or
  credentials, and irreversible destruction are never performed unless the user
  has authorized them upfront — in the run's instructions, or via
  `{{AUTHORIZED_REDLINE_EXCEPTIONS}}` in the project `CLAUDE.md`, and only within
  the stated scope. Unattended runs skip an unauthorized red-line action, mark
  "authorization needed" in the report, and move on instead of waiting for a human.
- **The four red lines are no longer blockchain-specific.** They are stated in
  general terms (payments/orders, credentials, irreversible destruction) with
  on-chain transactions as one example among many; project-specific red lines go
  in `{{IRREVERSIBLE_REDLINES}}`.
- **Slimmer skill description.** The description is the skill's only
  permanently-loaded text, so it now carries trigger conditions only — the
  methodology it used to repeat lives in the skill body. Also dropped
  "packaging", a trigger word with no matching content in the skill.
- **Deduplicated the skill body.** Committing, the red lines, and the report
  requirements each had two or three full copies; each now has a single
  authoritative home, with the Rules block reduced to a pure checklist.
- **Introduced "green zone"** as the counterpart to "red line" — everything
  reversible and low-risk (installing tools, local config, dependencies,
  scaffolding) that the agent should just finish and keep going, replacing six
  separate spellings-out of the same rule.
- **Report requirements are now a five-item completion bar** at the end of the
  autonomous loop, so the loop's final step has a checkable bound.
- **Section numbering fixed** — two sections previously both claimed to be the
  first step. Context gathering is §1, environment bootstrap is §2, and the
  device lookup states its dependency on the bootstrap explicitly.
- **`references/tool-decision-tree.md`** no longer caches the full `mobilecli`
  command surface. It keeps the traps and usages `mobilecli --help` cannot tell
  you, and points at `--help` for the rest.

### Fixed

- The README install badge is a static link until skills.sh install stats
  aggregate.

## [1.0.0] - 2026-08-14

### Added

- Initial release: autonomous Flutter on-device testing skill for Claude Code.
- Element-driven interaction over Semantics labels via `mobilecli`, replayable
  Patrol assertions by `Key`, an offline fixture test layer, screenshot and log
  verification, and an unattended implement → test → fix → commit loop.
- iOS (simulator first, WebDriverAgent for real devices) and Android (adb) at
  parity, with platform detail in `references/{ios,android}.md`.
- Project templates: a `CLAUDE.md` constitution, a permission allowlist with
  format/analyze hooks, and `/spec`, `/verify`, `/ship`, `/debug`, `/nightly`
  commands.
- Full English mirror under `skills/flutter-autonomous/en/`.

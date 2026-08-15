---
name: flutter-autonomous
license: MIT
compatibility: Requires Flutter SDK; Android via adb (mac/Linux); iOS via Xcode/simctl (macOS only); mobilecli/patrol_cli auto-installed by scripts/bootstrap.sh
metadata:
  author: z-chu
  version: "1.1.0"
description: Autonomous Flutter on-device/simulator run & UI verification (iOS + Android parity). Use for: running the app on a device/simulator to see how it looks, simulated taps/typing/swipes, screenshot visual verification, log capture for diagnosis, E2E/integration regression (Patrol by Key), or self-driving the implement→verify-on-device→fix→commit loop. **Only use it when the app must actually run so you can look at the UI; do NOT use it for writing plain unit tests / pure-logic tests** (just run flutter test). Autonomous Flutter on-device/simulator UI verification: tap/screenshot/log evidence, Patrol E2E regression. Not for writing plain unit tests.
---

# Autonomous Flutter Development & On-Device/Simulator Testing

You are entering "autonomous Flutter development mode": run the requirements → implementation → testing → fixing → committing loop end-to-end unsupervised, until the task list is done or the retry cap is hit. The methodology lives in this doc and `references/`; **never hardcode a project-specific value**: whatever the repo can tell you (package name, both platform ids, entry point) you **detect yourself**, and the device you **take live**. Only what a human alone knows (log anchors, hard toolchain requirements, co-existing apps, business red lines, commit policy) is read from the project-root `CLAUDE.md` — and **the run proceeds without one**, asking where §1 says to ask and staying conservative otherwise. iOS and Android are at parity — the interaction base is unified under `mobilecli`, and platform differences are encapsulated in `references/{ios,android}.md`.

---

## 0. What this skill is for (and when NOT to use it)

**It exists for exactly one reason: to get the app actually running on a device/simulator so you can tap it yourself, look at it yourself, and judge for yourself whether the UI is right.** That is the part unit tests cannot cover and never will — rendering, real-device interaction, system integration, behavior under real data. Without this method, an AI facing "check whether this page looks right" degrades into blind-coordinate adb: slow and blind.

| Task | Use this skill? |
|---|---|
| "Run the app and show me page X / the effect of this change" | ✅ **exactly this** |
| "Tap X and see if it crashes / navigates right", "is this layout misaligned on a real device" | ✅ |
| "Add E2E regression for this feature", "implement X and verify it all-green before committing" | ✅ |
| "Screenshot it in dark mode / at large font scale", "grep the logs to pin down this connection issue" | ✅ |
| **"Write a unit test for this parser/util function", "test this piece of pure logic"** | ❌ **No** — just write `test/` and run `flutter test`; **don't use a sledgehammer to crack a nut** |
| **"Run the existing tests and see if they pass"** | ❌ No — just `flutter test` |

> **The one-line criterion**: if the task **does not require the app to actually run and does not require looking at the UI**, this skill should not be invoked. Everything below about the offline test layer is a pre-filter used **when you are already inside the device loop** to save device time (see §Verification layering) — it is **not** a reason to treat this skill as a unit-test tool.

---

## 1. Gather context before you start (the project-agnostic foundation)

Before doing anything, pin down "which project is this" — **auto-detect, don't ask, don't hardcode**:

- **applicationId** (Android) ← `applicationId` in `android/app/build.gradle(.kts)`
- **bundleId** (iOS) ← `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj/project.pbxproj` (or the `patrol:` block in `pubspec.yaml`)
- **Entry point / dart-defines** ← debug configs in `.vscode/launch.json` or the project `CLAUDE.md`
- **Device** ← taken **live** at runtime from `mobilecli devices` after the §2 bootstrap; a device id lives only inside this run
- **Log anchors / toolchain constraints (JDK/Xcode) / co-existing apps on the same device / business red lines** ← project `CLAUDE.md`
- **Commit policy (ask once before starting)** ← **committing is not this skill's call**: whether to commit and how (commit as you go / one commit at the end / don't commit / something else) **is the user's decision**. If the project `CLAUDE.md` states a commit policy, or this session's instruction does, follow it; **if not, ask once before you start running**, then follow that answer throughout. Commit conventions (precise `git add`, message format, whether to push, trailers) follow the user's **global / project `CLAUDE.md`** — don't decide them here on the user's behalf.

**Detect once, don't re-detect at every step**: these values are stable within a project, so once you've detected them, **remember and reuse them for this session** — grepping `build.gradle` over and over inside one run is pure waste. If your environment has cross-session memory, store the **stable facts** there and use them directly next time: the package name and both platform ids, the entry point and dart-defines, how many platforms this project actually ships, where the Patrol tests live, roughly how long a cold build takes.

**But three kinds of thing are wrong to remember** — they're facts about *this moment*, not about *this project*, and caching them just means carrying a stale conclusion forward:

| Never cache | Why |
|---|---|
| Device id, VM Service port/URI | They change on every run (§1; `references/vm-service.md` §5) — **take them live** |
| Login state / wallet / seed data and other prerequisites | Getting in last time doesn't mean you can get in now. **Remember the route in** (which deeplink, what the debug hook is called, where the test account is fetched from), **not "I'm already in"** |
| Any credential itself | Red line ③ — remember where to fetch it, never the value |

---

## 2. Environment bootstrap: if a tool/dependency is missing, install it yourself — don't stop for a human

Once the context is clear, fill in the tooling immediately — **anything in the green zone (below), do it yourself and keep going; never stop to ask for a human**.
(Lesson learned: mobile-mcp wasn't registered → fell back to the least efficient blind-coordinate adb → hit a red line and got blocked → stopped for a human. It should have been installed during the self-check.)

One shot: `bash scripts/bootstrap.sh` (cross-platform mac/Linux, Android+iOS, idempotent and re-entrant: each item is **detect → install if missing → re-check → skip if already present**). Item by item:

| Check | Command | If missing (do it yourself) |
|---|---|---|
| Device online | `mobilecli devices` (if empty, then `adb devices` / `xcrun simctl list devices booted`) | All empty: Android `adb kill-server && adb start-server` — one self-recovery attempt; iOS simulator `xcrun simctl boot <udid>`; still empty = **physically disconnected/not started, only then stop** |
| **mobilecli** (interaction base) | `mobilecli --version` | Missing → `npm i -g mobilecli@latest`; **if npm can't install it, switch channels** (it's a Go binary, prebuilt assets exist on GitHub Releases — see `references/restricted-network.md`). Usable the moment it's installed, **no MCP/restart needed** |
| **mobile-mcp** (MCP flavor, optional) | `claude mcp list \| grep -i mobile` | Missing → `claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest` (**changing MCP config = only connects next session**; use mobilecli for this session, don't fall back to blind coordinates because of it) |
| **patrol_cli** | `patrol --version` | Missing → `dart pub global activate patrol_cli`; installed but "not found" → `export PATH="$PATH:$HOME/.pub-cache/bin"` |
| Project Patrol config | pubspec has the `patrol` dev_dep + a `patrol:` block + `integration_test/` | Missing → `flutter pub add patrol --dev` + add the `patrol:` block + Android `androidTest` scaffolding. A one-time project-level investment — **set it up and keep going** |
| node (for npx) | `node -v` (needs v22+) | Missing → install via fnm/nvm |
| **iOS-specific** (mac only) | see `references/ios.md` | Xcode CLT, simulators; physical devices go through WDA + provisioning (installing the agent on a physical device can reuse the app's own `build/ios/Debug-iphoneos/Runner.app/embedded.mobileprovision`); Linux has no iOS toolchain — Android only, automatically |

`npx mobilewright doctor --json` works as a cross-platform health-check entry point (covers Node/mobilecli/Xcode/Simulators/agent/Java/ADB); stack `flutter doctor` + patrol on top. Details in `references/android.md` and `references/ios.md`.

**Red lines (deny by default; only done with the user's explicit prior authorization)**: ① device physically disconnected/unplugged — a physical blocker; report and stop only after one self-recovery attempt fails; ② operations that spend real money / affect real users (payment/charging/transfer/placing orders; on-chain transactions in a blockchain app are the same thing); ③ key/credential operations (production keys/signing certificates/user credentials/private keys & mnemonics); ④ irreversible destruction (deleting data/modifying production). ②③④ are **never done by default**; the only unlock is the user's **explicit prior authorization** — stated in this session's instruction, or written in the project `CLAUDE.md`, specifying which category and what scope is allowed (e.g. "sandbox payments may place orders", "the test chain may send transactions") — and you only do what is spelled out there. When not authorized: an interactive session may stop and ask once; **unattended, don't ask and don't wait — skip that item, mark "needs authorization: <operation>" in the report, and move on to the next task**. Never treat "the test needs it" as authorization. Project-specific red lines written in the project `CLAUDE.md` carry equal force.

**Green zone (everything outside the red lines)**: installing tools, changing local config, adding dependencies, scaffolding tests, starting/stopping simulators, installing WDA/agent — reversible and low-risk, so **do it yourself and keep going**; never treat "the tool isn't installed" as a reason to stop. Every later mention of "green zone" means this.

**Re-check**: every later mention of "re-check" also means one thing — **prove the result with an independent command; never infer "X took effect" from "I ran X"**. Re-check the version after installing, where a tap landed, that a swipe moved something, the foreground after closing, connectivity after cutting the network. Device-side commands **routinely exit 0 even when they failed**, so the "result" half is yours to go and fetch. A re-check takes **machine-decidable evidence** (a dump comparison, the foreground package, a return code); eyeballing a screenshot for how it looks is the other thing — **screenshot verification** — and neither substitutes for the other.

**When an install fails, first tell "channel" from "permission"**:
- **Channel problem** (the package source is blocked — typically a corporate gateway blocking npm): **still the green zone** — the green zone is about the *goal*, not the *channel*, so take another route and keep going. `bash scripts/bootstrap.sh` already has an automatic GitHub Releases fallback built in; the manual route and its traps → `references/restricted-network.md`.
- **Permission problem** (only a human at the GUI can grant it: macOS Accessibility, the device's "Allow USB debugging" prompt, iOS Developer Mode, the `xcode-select --install` dialog): **a genuine stop**, on par with a physically disconnected device. Interactive: ask once. Unattended: skip and write "needs human authorization: click what, where" in the report, then move on to the next task.

**Likewise: the prerequisite state a feature needs (being logged in / a wallet / identity verification / seed data) belongs to the same "only a human can give it" class** — nothing can be verified behind a login wall, and it isn't something you can install your way past. **But don't lead with the question**: the device is usually already logged in (the user develops on this very machine), so launch the app and look first; if it isn't, try to route around it (a deeplink straight to the page under test, or a debug-only hook that sets state in one step via VM Service `evaluate` — see `references/vm-service.md` §3.6). **Stop only when you can't route around it**, and say exactly what you're stuck on and what's missing — the user may hand you a test account right there, tap through it themselves, or authorize you to register a test account (registering is green zone; **never touch a real user's account**, see red line ③). Once you have it, remember it for this session and keep going instead of asking at every step. Unattended: likewise skip, mark "needs a human: <what's missing>", and move on to the next task.

---

## Core insight: how to find Flutter widgets — three complementary paths

Flutter paints a canvas via Skia/Impeller, so the system accessibility tree is **by default** nearly empty — but that **does not mean widgets can't be found**:

1. **Direct Dart VM connection (Patrol / integration_test)**: walks the widget tree, locating by `Key` with exact matching + assertions, **repeatable, produces pass/fail**. → use it for **deterministic regression**. This is Flutter's only assertion path that doesn't depend on accessibility-tree exposure and is stable on both iOS and Android.
2. **Accessibility-tree driven (mobilecli `dump ui` / mobile-mcp `list_elements`)**: **as long as the widget exposes a `Semantics` label**, it returns label + **device-pixel rect**; take the center and tap directly, no conversion needed. → use it for **interactive exploration / navigation / one-off verification**; far faster and more accurate than blind coordinates. **It is the only one that can tap.**
3. **VM Service introspection (the channel `flutter run` already opened)**: without writing a test and without rebuilding, pull the widget tree (**with `Key` and source line numbers**), the render tree (**real constraints/size**), runtime state, and structured errors straight out of the running app. → use it when you need **diagnosis/evidence/assertions but no tapping**. See `references/vm-service.md`.

The division of labor: **to tap use ②, for evidence use ③, for regression use ①**. What makes ③ complementary to ② is that it **does not depend on the accessibility tree** — a widget with no `Semantics` wrapper that `dump ui` cannot list still shows up in the widget tree, with a source line number.

Only **pure canvas painting** (chart internals, elements with no `Semantics` wrapper) leaves all three unable to give coordinates **for the purpose of tapping** — that's the only case that falls back to "screenshot by eye + measure and convert coordinates". But for judging **whether something exists and whether it's right**, ③ still works — don't downgrade your *judgment* just because you can't tap.

---

## Tool decision tree (mobilecli is always the base)

| Scenario | Use | Key point |
|---|---|---|
| **Instant interaction/exploration** (tap, type, swipe) | **mobilecli** | Installed binary, no MCP/restart; `dump ui` → `io tap`, coordinate-level |
| **Diagnosis/evidence** (does the widget exist, which line painted it, layout size, any errors) | **VM Service** | The channel `flutter run` already opened, one curl; no Semantics dependency, carries source line numbers → `references/vm-service.md` |
| MCP tool flow (when registered) | **mobile-mcp** | Same engine, MCP-wrapped; `list_elements` → `click`; config changes only take effect next session |
| **Repeatable Flutter assertions** (into CI) | **Patrol** | Dart VM by Key, stable on both iOS and Android |
| TS repeatable scripts / system level / cross-app | mobilewright | `getByLabel().tap()` with auto-wait; but **Flutter is marked ⏳ not officially supported** — Flutter assertions still go to Patrol |
| Platform last resort (pure canvas, blind coordinates) | adb (Android) / simctl·WDA (iOS) | If Semantics exists, always go element-driven |

> ⚠️ **mobilecli / mobile-mcp are both coordinate-level** — there is no native "tap by label in one step" command (`query/getBy` only applies to webviews, not to native/Flutter Semantics). For one-step tapping use `scripts/tap-by-label.sh` (zero deps beyond jq). Selection details in `references/tool-decision-tree.md`.

---

## Element-driven interaction: the default (inspect first → tap the label's center)

When you need to "tap it yourself, look at it yourself, and keep moving" on the device (navigation, exploration, one-off interaction checks), **prefer this over blind coordinates**.

**Inspect first**: `dump ui` before you act — **never guess element names**.
**One step**: `scripts/tap-by-label.sh <deviceId> "<label substring>"` (internally dump → jq picks the rect by label → taps the center via `io tap`). The manual equivalent:

```bash
D=$(mobilecli devices | jq -r '.data.devices[0].id')   # output is {status,data:{devices:[…]}}; taken live at runtime, never hardcoded
UI=/tmp/ui.json; SHOT=/tmp/shot.png                     # dump/screenshot to a file, then pick — don't dump the whole blob into context
APP=<applicationId or bundleId>                         # you already detected it in §1 (build.gradle / project.pbxproj); differs per platform
mobilecli apps launch     --device "$D" "$APP"          # bring to foreground
mobilecli apps foreground --device "$D"                 # confirm foreground = target app (anti cross-talk)
mobilecli dump ui         --device "$D" > "$UI"         # label + device-pixel rect{x,y,width,height}
# pick the target by label, tap the rect center (x+width/2, y+height/2):
mobilecli io tap   --device "$D" <cx>,<cy>
mobilecli io swipe --device "$D" x1,y1,x2,y2            # sliders / list scrolling / pull-to-refresh
mobilecli io text  --device "$D" "text"                 # system text fields only
mobilecli io button --device "$D" BACK                  # go back (iOS has no BACK — use a gesture / tap the nav bar)
mobilecli screenshot --device "$D" -o "$SHOT"           # screenshot → Read to verify
```

**Flutter locator priority (most to least robust)**: Patrol `Key` (most robust for regression) > `Semantics(identifier:)` (immune to copy and locale changes) > exact `Semantics` label > role/`button:true` flag > label substring/regex > plain text > blind coordinates (last resort).

Key points: take coordinates from the `dump ui` rect center, **never guess**; Flutter's **custom-painted numeric keypads and custom gesture widgets are not system text fields** — `io text` won't reach them → tap each key's coordinates with `io tap`; if a widget can't be listed = it doesn't expose Semantics → **go fix the code** (below). Deeplink shortcut: `mobilecli device url <deeplink>` jumps straight to a page, skipping step-by-step navigation.

**The "silent failure" list — sent ≠ took effect.** The backend only guarantees "the event was dispatched", not "Flutter received and recognized it": `io swipe` (Flutter's scroll gestures are sensitive to a synthesized event's duration/step, and the typical symptom is a screen that doesn't move at all), a synthesized `io longpress` (a WDA-synthesized long-press may not be recognized on the Flutter side — typically a long-press `GestureDetector` on an AppBar title), and **tapping the blank area of a container that wraps your target** (after Semantics merging an ancestor's label naturally contains the substring, and in `dump ui` it comes *before* the leaf — pick the smallest rect by area). **Re-check these the moment you send them**: after a swipe, `dump ui` again and compare an anchor element's `rect.y` (or diff before/after screenshots); after a tap, re-check where it landed and `io button BACK` out if it landed wrong; if nothing moved, retry once with a longer distance / slower duration, and **if it doesn't move twice, change route** (deeplink straight to the page, or let the Dart side scroll itself via Patrol's `scrollTo`). For a gesture that simply **cannot be delivered — a long-press being the usual one — the fix is in the code**: replace it with a tappable widget that has `Semantics`, the same "can't list it = go fix the code" principle (which also makes manual testing better). A "tapped it, nothing happened" conclusion usually traces back to this paragraph.

---

## Code contract: every interactive/assertable widget gets a Key + Semantics

The two paths each consume a different thing — add both, and the widget becomes "testable by construction": `Key` for Patrol (named `<feature>_<widget_type>`, lowercase with underscores); `Semantics` for element-driven interaction. Standard `Text`/`ElevatedButton` text carries a label already; **custom gesture widgets (`Touchable`/`GestureDetector`/`InkWell`) can't be listed by default — always wrap them explicitly in `Semantics`**.

**A `label` changes, an `identifier` doesn't — give both.** `Semantics(label:)` is **human-readable visible copy**: reword it once, or switch locale once, and anything locating by it breaks (a multi-language project will hit this). `Semantics(identifier:)` (Flutter 3.19+) is **the stable id meant for automation**, mapping to Android's resource-id / iOS's accessibilityIdentifier, returned as the `identifier` field in `dump ui`, and already part of the match set in `scripts/tap-by-label.sh`. **Reuse the same name you gave `Key` as the `identifier`** — one naming feeds both Patrol and element-driven interaction, and you locate by it rather than by the label.

```dart
ElevatedButton(key: const Key('submit_btn'), onPressed: _submit, child: const Text('Submit'))

Semantics(label: 'Slide to buy', identifier: 'swap_slide_btn', button: true,   // custom gesture: without Semantics it won't show in dump
  child: GestureDetector(key: const Key('swap_slide_btn'), onTap: _buy, child: customSlider))

TextField(key: const Key('email_input'), controller: _c)
Text(_err, key: const Key('error_text'))
Scaffold(key: const Key('home_screen'), ...)        // page root: to judge "am I on this page"
```

> Self-check (manual): if `dump ui` can't list your widget = it doesn't expose Semantics → go back to the code and add `Semantics(label:)`. Treat "can't be tested" as a code defect to fix, not a reason to downgrade to blind coordinates.
>
> **Self-check (automatic — prefer this one)**: this contract is machine-checkable, so don't wait until you're on a device to find out. Add `await expectLater(tester, meetsGuideline(labeledTapTargetGuideline))` to a widget test — **a `GestureDetector` with no `Semantics` fails outright and reports its rect**; `androidTapTargetGuideline`/`iOSTapTargetGuideline` check whether the hit area is at least 48×48, and `textContrastGuideline` checks contrast. Sub-second, no device, and it turns "testable by construction" from a verbal convention into an assertion CI can block on. How to write it: `references/offline-test-layer.md`.

---

## Verification layering: the device layer is the main event; the offline layer exists to clear the way for it

**Get the priority straight first**: this skill's output is **evidence that the app really ran on a device and the UI really is right** — that's group B. Group A, the offline layer, exists to **filter out everything that doesn't deserve device time** (a pure-logic bug should not cost 30 minutes of real-device time to locate), so that device time is spent only on what only a device can verify. **A clears the way for B; it is not a substitute for B.**

**A. Offline layer — no device, sub-second; run it before going to the device** (details in `references/offline-test-layer.md`)

| Layer | Verifies | How |
|---|---|---|
| ① **Pure-logic fixtures** | decode/parse/numerics/state machines/error handling | `flutter test` / `dart test` + fixtures/mocks (four strategies: real-data JSON / hand-built bytes / forTesting injection / probe) |
| ② **widget test** | a **behavioral regression net** for widget interaction/navigation/forms/conditional rendering | `testWidgets` + `tester.tap` + assertions by `Key`. Locks in "no logical regression"; **says nothing about whether it works on a real device** |
| ③ **golden matrix + a11y guideline** | visual regression (theme × font-scale matrix) / accessibility-contract self-check | `matchesGoldenFile` gives a **quantified diff plus an image of only the changed region**; `meetsGuideline` automatically catches missing labels, undersized hit areas, insufficient contrast |

**B. Device layer — this skill's main event: real rendering, real-device interaction, system integration, real data**

| Layer | Verifies | How |
|---|---|---|
| ④ **VM Service introspection (evidence)** | does the widget exist / which line painted it / real layout size / did this step error | one curl for the widget tree (with Key + line numbers), the render tree (constraints/size), `errorsSinceReload` → `references/vm-service.md` |
| ⑤ **Element-driven (one-off)** | interaction/navigation/data display on a real device | `dump ui` → tap the center + screenshot |
| ⑥ **Patrol (repeatable)** | same as ⑤ but as a regression assertion, into CI | by Key, produces pass/fail |
| ⑦ **Logs (evidence)** | connections/state machines/gating — **use logs, not screenshots, to prove something did or didn't happen** | `adb logcat -s flutter` (Android) / `flutter logs` / `xcrun simctl spawn <udid> log stream` (iOS); clear the buffer → perform the action → read only that step's log window, then assert |

**Loop order**: `flutter analyze` → `flutter test` (①②③ in one sub-second run) → element-driven/VM Service (one-off) → Patrol (repeatable). **Get the offline layer all-green before going to the device.**

**Iron rules for picking a layer (both directions matter — don't remember only half)**:

**→ Downward (save device time)**: `null` checks, parse failures, wrong arithmetic — **pure-logic bugs must not cost real-device time to locate**; the offline layer pinpoints the line in seconds. Likewise, repeatedly-regressed static visuals (layout in dark mode / at large font scale) can be locked down with goldens instead of being eyeballed every time. **The offline layer exists so device time goes where it counts.**

**← Upward (never pass offline-green off as UI-verified) — this one matters more**: widget tests run in a **headless environment** — no real rendering pipeline, no real font metrics, no platform channels, no real-device timing. They can prove "logically it should display X"; they **cannot prove "it looks right on a real device"**. So: if you changed UI, run it on a device once and take a screenshot — goldens are only a regression net, not a substitute for looking at it yourself this time; **when in doubt about whether to go to the device, go**. The cost of missing a UI problem far exceeds the cost of one extra device run.

**Choosing within the device layer (once you've decided to go on-device)**: "can't find the widget / is the Key right / why is the layout skewed" — **don't screenshot first**; use ④ to read the widget tree and constraints, jump straight to the source line, then screenshot to confirm the look.

---

## The full autonomous loop + failure decision tree

```
read the task → self-expand acceptance criteria (3–8 assertable items, each tagged with its layer)
  → write the implementation (Key+Semantics on key widgets) + companion tests (whatever offline ①②③ can cover goes offline first)
  → flutter analyze (zero warnings)
  → flutter test (offline layers ①②③)   ── failing? logic/behavior/visual-contract bug; fix it without touching a device
  → confirm a device is online (mobilecli devices; one self-recovery attempt, stop only if still offline)
  → patrol test --device <id> -t integration_test/<feature>_test.dart
      ├─ pass → screenshot verification → (per the user's commit policy: incremental / final / none) → emit the report
      └─ fail → failure analysis (≤5 rounds; if a widget can't be found, check the VM Service widget tree first) → fix → rerun
                still failing after 5 rounds → stop, emit a "stuck" report, move on to the next task
```

**Step one — self-expanding the acceptance criteria — is the steering wheel of the whole loop**: everything that follows (what to run, tap, and look at) is decided by it. Break a one-line requirement into 3–8 items that can be **judged true or false**, and tag each one with its layer right then; **if you can't tag a layer, that item isn't assertable yet** — rewrite it before starting.

The requirement "add a *Remember me* option to the login page" expands to:

| # | Acceptance item (true/false decidable) | Layer |
|---|---|---|
| 1 | With it checked, kill and relaunch: the email field is pre-filled with the last value | ② widget test (persistence logic) |
| 2 | With it unchecked, relaunch: the email field is empty | ② widget test |
| 3 | On a real device the checkbox is tappable, the checked state is visibly clear, and it isn't muddy in dark mode | ⑤ element-driven + screenshot (**only a device can prove this**) |
| 4 | A successful login lands on the home page with no new Flutter errors along the way | ⑥ Patrol + ④ `errorsSinceReload` |

Counter-examples: "Remember me works fine", "the experience is smooth" — not decidable, and impossible to tag with a layer.

**How many platforms to run is decided by the nature of the change.** First check how many the project actually ships (the `android/` and `ios/` directories, which artifacts CI builds) — **run the platforms the project actually ships**, and a single-platform project runs that one only:

- **Ships both + the change touches platform differences → both are mandatory**: platform channels/native plugins/permission dialogs/IME & keyboard/safe areas & notches/system back gesture, or a layout sensitive to font metrics.
- **Ships both but the change touches none of those** (pure Dart logic, pure Flutter-painted UI): **one platform, run thoroughly, is enough** — write in the report "verified on <platform> only; reason: the change involves no platform differences".
- **Order**: if you have a simulator, simulator first (fast, multiple instances, cheap failures), then a real device once it's green (verifies real performance/permissions/physical interaction); if all you have is a real device, go straight there — don't install a simulator just for this.
- **But one class of things a simulator cannot give you, and its green is a fake green — that class goes straight to a real device**: screenshot protection and secure layers (`FLAG_SECURE` / iOS secure layer — a simulator still captures fine, which looks exactly like "it didn't work"), real performance and jank, biometrics, push notifications, camera and sensors, integrity/attestation SDKs, real network conditions and weak networks. **The test**: if what's under test depends on a capability or constraint only a real device has, skip the simulator tier.
- **You want to but can't** (Linux has no iOS toolchain, you don't have that physical device): run what you can thoroughly, and mark what you can't as "not verified: <platform>, reason: <no toolchain / no device>" — **never write single-platform green as both-platform green**.

**Before each acceptance item, reset the app to a known starting point.** Whatever state the previous item left behind becomes the next item's wrong starting point — parked inside a bottom sheet, a filter panel still open, stuck halfway through a form — and **it drifts further with every item while the report shows nothing wrong** (every screenshot "has content"; it's just the wrong page being verified). Running unattended, that drift compounds item by item. The reset is three steps: `apps terminate` → `apps launch` → `dump ui` to confirm you landed on the expected starting point. A few seconds buys off the risk of an entire item being invalid. The starting point gets **re-checked** like teardown does: you're on the home screen when `dump ui` says you are.

**Completion bar (the report)**: the loop ends in a report that must contain ① `✅/❌ feature name` + a **per-item acceptance table** (including items stuck at round 5) ② the list of changed files ③ key screenshots ④ (if committed per policy) commit hash + message ⑤ open issues. **Missing any one of these means it isn't done** — when running unattended, this evidence is what you harvest in the morning, not "it said it finished".

**Failure classification**: compile errors → read the `flutter analyze` output and fix; `found 0 widgets` → **pull the widget tree from the VM Service first to check the Key** (it carries source line numbers, faster than grepping code), then check whether a scroll / conditional render is needed; assertion failures → **it's a logic bug, fix the implementation, don't lower the test's bar**; crash/timeout → `mobilecli device crashes list|get` and read the first stack line matching `package:<your_app>/`; install/connection → `mobilecli devices` + one self-recovery attempt, stop if it still fails.

**Patrol commands**: `patrol test -t <file> --device <id> [--timeout 300]` (builds + installs + runs); on build failure `flutter clean && flutter pub get && patrol test`. Template:

```dart
import 'package:patrol/patrol.dart';
import 'package:<your_app>/main.dart';                 // replace with the real package name

void main() => patrolTest('user can log in with email', ($) async {
  await $.pumpWidgetAndSettle(const MyApp());
  await $(#email_input).enterText('test@example.com');
  await $(#submit_btn).tap();
  await $.pumpAndSettle();
  expect($(#home_screen), findsOneWidget);             // common: $(#key)/$(Text('...'))/.tap()/.enterText()/.scrollTo()
});
```

---

## Backgrounding flutter run + three-tier hot reload (change a line, send a signal)

**Precondition**: if the device is already occupied by another `flutter run` (e.g. a VS Code debug session), free it first — `ps aux | grep "flutter_tools.snapshot run" | grep -v grep`; if there is one, ask the user to stop it before continuing, don't force-start.

**Launch**: the command **must start with `flutter run`** (if your permission rules match by prefix, e.g. `Bash(flutter run:*)`, **wrapping** it in nohup/pipes/`&` gets blocked). Backgrounding is done with the `run_in_background: true` parameter; pass `--pid-file` (default `/tmp/flutter_app.pid`; append a project or device suffix when running several devices/sessions concurrently so they don't collide).

**You also have to keep the build output readable**: once backgrounded, the real reason a build failed lives only in that output. Appending `> <LOG_FILE> 2>&1` is the simplest way (a redirect at the end of the command usually doesn't affect prefix matching); if your permission setup blocks it, **don't fight it** — read the background task's own output through whatever your harness provides. **Keep something you can `tail`; the form doesn't matter.**

```bash
flutter run -d <deviceId> --target <entry> \
  --pid-file=<PID_FILE> --vmservice-out-file=<URI_FILE> <dart-defines — see §1 for where they come from> \
  > <LOG_FILE> 2>&1
```

**Waiting for the build** (a long-lived process never notifies you on its own — poll from a separate background Bash). **What you wait on is `--vmservice-out-file` landing on disk** — a non-empty file means the app is up and the VM Service is ready: a binary signal, no parsing of human-readable output. But **waiting only on the success signal will hang forever**: there are too many ways a build can fail (Gradle/CocoaPods/signing/`No supported devices`) and an enumerated grep pattern will always miss one, so **the other two exits must be there too** — process died, and timeout:

```bash
DEADLINE=$((SECONDS+600))                       # just an alarm clock saying "come check on it" — not a failure verdict (see below)
while [ ! -s "<URI_FILE>" ]; do
  P=$(cat "<PID_FILE>" 2>/dev/null)
  if [ -n "$P" ] && ! kill -0 "$P" 2>/dev/null; then echo "❌ flutter run exited"; break; fi
  if [ "$SECONDS" -ge "$DEADLINE" ];        then echo "⏳ not ready yet — come look"; break; fi
  sleep 2
done
[ -s "<URI_FILE>" ] && echo "✅ VM Service ready" || tail -40 "<LOG_FILE>"   # if it isn't ready, the real reason is here
```

> The three exits map to "it's up / it died / it's not ready yet". **Only "the process exited" is a failure verdict**; reaching the deadline is **not** — a cold-checkout first Gradle/CocoaPods build, a large project, a slow network, or a CI container can all legitimately take half an hour. When the alarm fires, read the tail of `<LOG_FILE>`: **process still alive and the log still growing = it's still compiling, so wait another round** (double the limit; don't make it unbounded). Only a log parked on an error is genuinely stuck. **The alarm means "come back and look", nothing more** — reading it as a failed build and `flutter clean`-ing to start over turns one slow build into two.
>
> How long the limit should be is project-specific: a warm incremental build is tens of seconds, a cold first build tens of minutes. **600 is only a starting value — one run tells you what this project needs**.

The URI you get is also the entry point for §Verification layering ④ (convert to http, then one curl for the widget tree/layout/errors) — see `references/vm-service.md`.

**Three-tier hot reload, the iron rule** (always launch with `--pid-file`, otherwise you can't send the signal and every one-line change costs a cold start of tens of minutes):

| What you changed | Which tier |
|---|---|
| UI/styling/method bodies/ordinary logic | **① hot reload** `kill -USR1 $(cat <PID_FILE>)` (injects new code, keeps state) |
| Field initializers / `main()` / DI registration / route tables / **the initial state of already-instantiated controllers & singletons** / global variables | **② hot restart** `kill -USR2` (clears state and reruns main, reusing compiled artifacts — faster than a cold start) |
| **Codegen inputs**: `.arb`/l10n strings, freezed & json_serializable annotations, drift schemas | **run the generator first** (`gen-l10n` / `build_runner`), **then ② USR2** — a bare USR1 shows you the stale generated output, which is easily misread as "my change didn't take" and sends you off editing working code |
| `android/`·`ios/` native code / `pubspec.yaml` (adding/removing deps & assets) / a new plugin containing native code / engine·channels | **③ cold start** (stop it and `flutter run` again) |

Mnemonic: Dart method body → USR1; initialization/registration/main/routes → USR2; **codegen inputs → generate first, then USR2**; native/pubspec/plugins → cold start; **when unsure, USR2 first** (still faster than a cold start).

> **To re-check whether a reload succeeded, switch to a channel that answers back**: `kill -USR1` is fire-and-forget — it leaves you grepping output and guessing. When you must confirm "did this reload actually take", use `app.restart` over `flutter run --machine` — it **returns `{"code":0,"message":"Reloaded N libraries"}`**, and `code!=0` is the assertion itself. See `references/vm-service.md` §2.4. For casual day-to-day reloads, the signal is still less hassle.

---

## Teardown (kill flutter run ≠ closing the app) + anti cross-talk

**Anti cross-talk**: several apps can co-exist on one device (different applicationId/bundleId, not overwriting each other). Before screenshotting/tapping, confirm the foreground is the target package: `mobilecli apps foreground --device <id>` (or Android `adb ... dumpsys activity activities | grep mResumedActivity`); before reading logs, identify the target app's PID (every Flutter app's `I/flutter` goes into logcat).

**Two teardown steps + re-check** (`kill flutter run` only severs the host; the app keeps running on the device):
```bash
kill "$(cat <PID_FILE>)" 2>/dev/null                      # 1) stop the flutter run host
mobilecli apps terminate --device <id> <appId>            # 2) actually close the app (Android=am force-stop / iOS=simctl terminate; mobilecli abstracts it)
# 3) terminate leftover apps from other projects on the same device too; re-check the foreground isn't a leftover app
```
**Before announcing "tested/stopped", re-check the real state.** **Device system state you changed during testing must be restored and re-checked too** — if you cut the network, you must verify it's back (`svc wifi enable` hangs on some models; the reliable recovery path is in `references/android.md` §10).

---

## Platform details, advanced topics & portability

- **VM Service introspection** → `references/vm-service.md` (the third path: widget tree with source line numbers / render tree with real sizes / structured errors / evaluate for runtime state / toggling dark mode at runtime; the HTTP vs WS capability boundary)
- **iOS parity** → `references/ios.md` (`xcrun simctl` simulators first / WebDriverAgent for physical devices / go-ios / device trust & provisioning / determinism switches / terminate on teardown)
- **Android details** → `references/android.md` (adb paths/wm size/dumpsys/logcat/determinism switches like disabling animations/performance metrics/offline testing and recovery; the platform last resort)
- **Offline test layer** → `references/offline-test-layer.md` (four fixture strategies + widget tests + golden matrix + a11y guidelines)
- **Tool selection** → `references/tool-decision-tree.md` (when to use mobilecli/mobile-mcp/mobilewright/Patrol)
- **Restricted network/permissions** → `references/restricted-network.md` (fallback channels when a corporate gateway blocks npm, macOS exec bit & quarantine, which blockers only a human can clear)
- **Scaling/unattended** → `references/scaling.md` (the trust ladder, worktree/subagent/workflow parallelism, /schedule·/loop)
- **Project rollout**: `templates/` (a `.claude/settings.json` permission allowlist + format/analyze hooks + `.claude/commands/{spec,verify,ship,debug,nightly}.md`). One-shot install: `bash setup-project.sh <project-root>` — it **only writes into `.claude/`, never your project root** (see README).

---

## Rules — hard-principle checklist (don't drop one; the mechanics live in their own sections, this is only for checking)

**Always**
1. Bootstrap the environment first; anything in the **green zone**, do it yourself and keep going (§2).
2. `dump ui` to inspect before interacting; locate by Key/label and take the **smallest match by area**; **re-check** after every `io swipe` / long-press (§Element-driven interaction).
3. Double-tag interactive/assertable widgets with `Key` + `Semantics`; if `dump ui` can't list it, go fix the code, and use `meetsGuideline` so it gets caught automatically from then on (§Code contract).
4. **If you changed UI, you must run it on a device once and verify by screenshot** — `flutter test` all-green **does not mean** the UI is right (§Verification layering, "← Upward"); whenever the task says "run it and see / how does it look / is it misaligned", go to the device; never close it out with "the unit tests passed".
5. Locate pure-logic bugs in the offline layer in seconds and leave static visual regression to goldens — **the point is to reserve device time for what genuinely needs looking at**.
6. Self-expand the acceptance criteria into 3–8 assertable items and tag each with its layer; **reset to a known starting point** before each item; decide how many platforms by the nature of the change, write single-platform green up as single-platform green, and go straight to a real device for what a simulator can't give you (§The full autonomous loop).
7. Can't find a widget / layout is skewed / suspect an error → **check the VM Service first** (widget tree with source line numbers, render tree with real constraints); don't start by eyeballing screenshots.
8. Change code via `--pid-file` + `USR1`/`USR2`; if you changed a codegen input (`.arb`/freezed/drift), **run the generator before USR2**; to **re-check** a reload, use `app.restart` over `--machine`. Give a build wait all three exits — "it's up / it died / it's stuck" (§Backgrounding flutter run).
9. Two teardown steps to close the app, then **re-check** the foreground; **no re-check, no completion claim**.
10. An assertion failure is a logic bug: fix the implementation, don't change the test; self-repair **≤5 rounds** (round 3: record what you've tried; round 4: change approach; round 5: stop, emit a stuck report, move on).
11. Emit all five items of the **completion bar**; missing one means not done.
12. Commit per the user's commit policy (§1); never auto-commit by default.

**Never — the four red lines** (deny by default; the only unlock is the user's explicit prior authorization with the scope written out; see §2): ① device physically disconnected (stop only after one self-recovery attempt fails) ② operations that spend real money ③ key/credential operations ④ irreversible destruction + project-specific red lines from the project `CLAUDE.md`. When not authorized: interactive may ask once; unattended, skip and mark "needs authorization" — don't block waiting for a human.

**Never — two anti-patterns** (every other failure mode is the inverse of an Always rule above; read the positive one instead):
- **Reporting a result without re-checking it** — device-side commands routinely exit 0 on failure, so "I ran it" is still one re-check away from "it took effect" (most common: taking `io swipe`'s exit code 0 as a successful swipe).
- **Passing "the offline tests are all green" off as "the UI is verified"** — the #1 anti-pattern: not going on-device when you should have, and a report with not a single screenshot.

> The second is **the one to guard hardest**: the first costs efficiency and accuracy, the second is **claiming completion without doing the work** — this skill's whole value is in that screenshot and that real run.

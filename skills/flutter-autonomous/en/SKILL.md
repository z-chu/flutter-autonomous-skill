---
name: flutter-autonomous
license: MIT
compatibility: Requires Flutter SDK; Android via adb (mac/Linux); iOS via Xcode/simctl (macOS only); mobilecli/patrol_cli auto-installed by scripts/bootstrap.sh
metadata:
  author: z-chu
  version: "1.1.0"
description: Autonomous Flutter on-device/simulator run & test verification (iOS + Android parity). Use for: running a Flutter app on a device/simulator to see it work, simulated taps/typing/swipes, screenshot visual verification, log capture for diagnosis, E2E/integration regression (Patrol by Key), fast offline fixture unit tests, or self-driving the implement→test→fix→commit loop.
---

# Autonomous Flutter Development & On-Device/Simulator Testing

You are entering "autonomous Flutter development mode": run the requirements → implementation → testing → fixing → committing loop end-to-end unsupervised, until the task list is done or the retry cap is hit. The methodology lives in this doc and `references/`; **project-specific values (package name/device/dart-define/log anchors/toolchain/co-existing apps/business red lines) are always read from the project-root `CLAUDE.md`** — if there is none, bootstrap one from `templates/CLAUDE.md` (see §Portability). iOS and Android are at parity — the interaction base is unified under `mobilecli`, and platform differences are encapsulated in `references/{ios,android}.md`.

---

## 1. Gather context before you start (the project-agnostic foundation)

Before doing anything, pin down "which project is this", **auto-detect, don't ask, don't hardcode**:

- **applicationId** (Android) ← `applicationId` in `android/app/build.gradle(.kts)`
- **bundleId** (iOS) ← `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj/project.pbxproj` (or the `patrol:` section of Flutter `pubspec.yaml`)
- **Entry point / dart-defines** ← debug config in `.vscode/launch.json`, or the project `CLAUDE.md`
- **Device** ← fetched live from `mobilecli devices` after the §2 bootstrap; **never write a device id into any file**
- **Log anchors / toolchain constraints (JDK/Xcode) / co-existing apps on the same device / business red lines** ← project `CLAUDE.md`
- **Commit policy (ask up front)** ← **committing is not this skill's job**: whether to commit, and how (commit-as-you-go / one commit at the end / don't commit / other requirements) **is the user's call**. If the project `CLAUDE.md`'s `{{COMMIT_POLICY}}` or this run's instructions already state it, follow that; **if nothing is stated, ask once before starting**, and once clarified follow it for the whole run. Commit conventions (exact `git add`, message format, whether to push, signature) follow the user's **global / project `CLAUDE.md`** — don't decide them here on the user's behalf.

If you can't read it, first create the project `CLAUDE.md` (fill in `templates/CLAUDE.md`); don't proceed with hardcoded values.

---

## 2. Environment bootstrap: if a tool/dependency is missing, install it yourself, don't stop for a human

Once the context is clear, fill in the tools immediately — **anything in the green zone (below), finish it yourself and keep going, never stop and ask for a human**.
(Lesson: mobile-mcp wasn't registered → fell back to the least efficient blind-tap adb → hit a red line and got blocked → stopped to ask for a human. It should have been installed at the self-check stage.)

One-shot: `bash scripts/bootstrap.sh` (cross-platform mac/Linux, Android+iOS, idempotent and re-entrant: each item is **detect → install if missing → re-verify with an independent command → skip if already installed**). Manual, item by item:

| Check | Command | What to do if missing (do it yourself) |
|---|---|---|
| Device online | `mobilecli devices` (if empty, then `adb devices` / `xcrun simctl list devices booted`) | All empty: Android `adb kill-server && adb start-server` to self-recover once; iOS simulator `xcrun simctl boot <udid>`; still empty = **physically disconnected/not started, only then stop** |
| **mobilecli** (interaction base) | `mobilecli --version` | Missing → `npm i -g mobilecli@latest` (or `npx mobilecli@latest` / build from source `make build`). Usable as soon as installed, **no MCP/restart needed** |
| **mobile-mcp** (MCP version, optional) | `claude mcp list \| grep -i mobile` | Missing → `claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest` (**changing MCP config = only connects next session**; for this session use mobilecli to cover, don't fall back to blind-tap because of it) |
| **patrol_cli** | `patrol --version` | Missing → `dart pub global activate patrol_cli`; installed but reports not found → `export PATH="$PATH:$HOME/.pub-cache/bin"` |
| Project Patrol config | pubspec has `patrol` dev_dep + `patrol:` section + `integration_test/` | Missing → `flutter pub add patrol --dev` + add the `patrol:` section + Android `androidTest` scaffold. A one-time project-level investment, **install it and continue** |
| node (used by npx) | `node -v` (needs v22+) | Missing → install via fnm/nvm |
| **iOS-only** (mac only) | see `references/ios.md` | Xcode CLT, simulator; real device goes via WDA+provisioning (to install the agent on a real device, just use the app's own `build/ios/Debug-iphoneos/Runner.app/embedded.mobileprovision`); Linux has no iOS toolchain, automatically runs Android only |

`npx mobilewright doctor --json` works as a cross-platform health-check entry point (covers Node/mobilecli/Xcode/Simulators/agent/Java/ADB), then layer on `flutter doctor` + patrol. See `references/android.md`, `references/ios.md` for details.

**Red lines (denied by default — unlocked only by explicit upfront user authorization)**: ① device physically disconnected/unplugged — a physical blocker: self-recover once, still failing → stop and report; ② operations that spend real money or affect real users (payments/charges/transfers/orders; on-chain transactions for blockchain apps); ③ secret/credential operations (production keys/signing certs/user credentials/private keys & mnemonics); ④ irreversible destruction (deleting data/changing production). ②③④ are **never done by default**; the only unlock is **explicit upfront authorization from the user** — in this run's instructions, or in the project `CLAUDE.md`'s `{{AUTHORIZED_REDLINE_EXCEPTIONS}}` stating which class and what scope (e.g. "sandbox payments may place orders", "testnet transactions allowed") — and only within the stated scope. When not authorized: an interactive session may pause and ask once; **unattended, never ask and wait — skip the item, mark "authorization needed: <operation>" in the report, move on**. "The test needs it" is never authorization. Project-specific red lines added via `{{IRREVERSIBLE_REDLINES}}` carry the same force.

**Green zone (everything outside the red lines)**: installing tools, changing local config, adding dependencies, scaffolding tests, booting/stopping simulators, installing WDA/agent — reversible, low-risk, **finish them yourself and keep going**; don't treat "the tool isn't installed" as a reason to stop. Every later mention of "green zone" means this.

---

## Core insight: how to find Flutter widgets — two complementary paths

Flutter draws to a canvas with Skia/Impeller, and the system accessibility tree is **almost empty by default**, but that **does not mean widgets can't be found**:

1. **Dart VM direct connection (Patrol / integration_test)**: walks the widget tree, finds precisely by `Key` + asserts, **repeatable, produces pass/fail**. → Use this for **deterministic regression**. This is Flutter's only assertion path that doesn't depend on accessibility-tree exposure and is stable on both iOS/Android.
2. **Accessibility-tree-driven (mobilecli `dump ui` / mobile-mcp `list_elements`)**: **as long as the widget exposes a `Semantics` label**, returns label + **device pixel rect**, take the center and tap directly, no conversion needed. → Use this for **interactive exploration/navigation/one-off verification**, faster and more accurate than blind-tap coordinates.

Only **pure canvas drawing** (inside a chart, elements not wrapped in Semantics) is unfindable by both paths — that's when you fall back to "screenshot by eye + measure-coordinate conversion".

---

## Tool decision tree (the base is always mobilecli)

| Scenario | What to use | Key |
|---|---|---|
| **Instant interaction/exploration/diagnosis** (preferred for autonomous runs) | **mobilecli** | Installed binary, no MCP/restart; `dump ui`→`io tap` at the coordinate level |
| MCP tool flow (when registered) | **mobile-mcp** | Same engine MCP-ified, `list_elements`→`click`; config changes only take effect next session |
| **Repeatable Flutter assertions** (into CI) | **Patrol** | Dart VM by Key, stable on both iOS/Android |
| TS repeatable scripts/system-level/cross-app | mobilewright | `getByLabel().tap()` auto-wait; but **Flutter is marked ⏳ not officially supported**, Flutter assertions still use Patrol |
| Platform last resort (pure canvas blind-tap) | adb (Android) / simctl·WDA (iOS) | If Semantics exists, always go element-driven |

> ⚠️ **mobilecli / mobile-mcp are both coordinate-level**, there's no native "tap by label in one step" command (`query/getBy` only acts on the webview, not on native/Flutter Semantics). For one-step use `scripts/tap-by-label.sh` (zero-dependency jq). See `references/tool-decision-tree.md` for selection details.

---

## Element-driven interaction: preferred (inspect first → tap label center)

When you need to "tap yourself, look yourself, drive forward smoothly" on the device (navigation, exploration, one-off interaction verification), **prefer this path, not blind-tap coordinates**.

**Inspect first**: before doing anything, `dump ui`, **never guess element names**.
**One step**: `scripts/tap-by-label.sh <deviceId> "<label substring>"` (internally dump→jq picks the rect center by label→`io tap`). Manual equivalent:

```bash
D=$(mobilecli devices | jq -r '.data.devices[0].id')   # output is {status,data:{devices:[…]}}; or read from project CLAUDE.md
mobilecli apps launch     --device "$D" <packageName>   # bring to foreground
mobilecli apps foreground --device "$D"                 # confirm foreground = target package (anti cross-talk)
mobilecli dump ui         --device "$D" > "$UI"         # label + device pixel rect{x,y,width,height}
# pick the target by label, tap the rect center (x+width/2, y+height/2):
mobilecli io tap   --device "$D" <cx>,<cy>
mobilecli io swipe --device "$D" x1,y1,x2,y2            # slider / list scroll / pull-to-refresh
mobilecli io text  --device "$D" "text"                 # system input field
mobilecli io button --device "$D" BACK                  # go back (iOS has no BACK, use gesture / nav-bar tap)
mobilecli screenshot --device "$D" -o "$SHOT"           # screenshot → Read to verify
```

**Flutter locator priority (most stable to most fragile)**: Patrol `Key` (most stable for regression) > `Semantics` label exact > role/`button:true` flag > label substring/regex > plain text > blind-tap coordinates (last resort).

Key points: take coordinates from the `dump ui` rect center, **don't blind-guess**; verify each step with `screenshot`+Read, tapped wrong → `io button BACK` to go back; Flutter's **self-drawn numeric keypad/custom gesture widgets are not system input fields**, `io text` won't feed into them → tap each key coordinate one by one with `io tap`; a widget that won't list = no Semantics exposed → **go back and fix the code** (below), don't make do with blind-tap. Deep-link jump: `mobilecli device url <deeplink>` reaches the page directly, saving level-by-level navigation.

---

## Code contract: add Key + Semantics to every interactive/assertable widget

The two paths each consume one; add both so a widget is "testable by birth": `Key` for Patrol (named `<feature>_<widget-type>` lowercase underscore); `Semantics(label:)` for element-driven. Standard `Text`/`ElevatedButton` text carries a label automatically; **custom gesture widgets (`Touchable`/`GestureDetector`/`InkWell`) won't list by default, you must explicitly wrap them in `Semantics(label+button:true)`**.

```dart
ElevatedButton(key: const Key('submit_btn'), onPressed: _submit, child: const Text('Submit'))

Semantics(label: 'Slide to buy', button: true,       // custom gesture: won't dump if not wrapped in Semantics
  child: GestureDetector(key: const Key('swap_slide_btn'), onTap: _buy, child: customSlider))

TextField(key: const Key('email_input'), controller: _c)
Text(_err, key: const Key('error_text'))
Scaffold(key: const Key('home_screen'), ...)        // page root: to judge "am I on a given page"
```

> Self-check: if `dump ui` won't list your widget = no Semantics exposed → go back and add `Semantics(label:)` in code, treat "can't be tested" as a code defect to fix, don't downgrade to blind-tap.

---

## Four verification layers: pick the hardest evidence by type of change

| Layer | What it verifies | How to verify |
|---|---|---|
| ① **Offline fixture (seconds, no device)** | Pure logic: decoding/parsing/numbers/state machines/error handling | `flutter test` / `dart test` + fixture/mock, see `references/offline-test-layer.md` (four strategies: real-data JSON / hand-built bytes / forTesting injection / probe) |
| ② **Element-driven (one-off)** | Widget interaction / page navigation / data display | `dump ui`→tap center + screenshot |
| ③ **Patrol (repeatable)** | Same as ② but needs regression assertions, into CI | by Key, produces pass/fail |
| ④ **Logs / screenshots (evidence)** | Use **logs** for connection/state machine/gating (hardest); use **screenshots** for visual/layout | `adb logcat -s flutter` (Android) / `flutter logs` / `xcrun simctl spawn <udid> log stream` (iOS); grep the connection URL/state name/`RenderFlex overflowed` (with file:line) |

**Loop order**: `flutter analyze` → `flutter test` (offline layer, seconds) → element-driven (one-off) → Patrol (repeatable). **Get the offline layer green before going to the device** to save device time; logic you can prove offline shouldn't go to a real device.

---

## Full autonomous development loop + failure decision tree

```
read task → self-expand acceptance criteria (3~8 assertable items) → write implementation (add Key+Semantics to key widgets) + write Patrol/offline tests
  → flutter analyze (zero warnings)
  → flutter test (offline layer)        ── fails? pure logic bug, fix directly without going to the device
  → confirm device online (mobilecli devices; if still offline after one self-recovery, only then stop)
  → patrol test --device <id> -t integration_test/<feature>_test.dart
      ├─ pass → screenshot verify → (per user's commit policy: incremental commit / final commit / no commit) → emit report
      └─ fail → failure analysis (≤5 rounds) → fix → rerun; still failing after 5 rounds → stop, emit stuck report, continue to next task
```

**Completion bar (the report)**: the loop ends in a report that must contain ① `✅/❌ feature name` + **item-by-item acceptance checklist** (including anything stuck at round 5) ② changed-file list ③ key screenshots ④ (if committed per policy) commit hash + message ⑤ outstanding issues. **Missing any one of these means not done** — unattended, you harvest in the morning from this evidence, not from "it said it was done".

**Failure classification**: compile error → read the error from `flutter analyze` and fix; `found 0 widgets` → check Key spelling / whether scroll is needed / conditional rendering; assertion fail → **it's a logic bug, fix the implementation, don't change the test to lower the bar**; crash/timeout → `mobilecli device crashes list|get` read the first line of the stack `package:<your_app>/`; install/connect → `mobilecli devices` + one self-recovery, still failing → stop.

**Patrol commands**: `patrol test -t <file> --device <id> [--timeout 300]` (auto build+install+run); build fails `flutter clean && flutter pub get && patrol test`. Writing template:

```dart
import 'package:patrol/patrol.dart';
import 'package:<your_app>/main.dart';                 // replace with the actual package name

void main() => patrolTest('user can log in with email', ($) async {
  await $.pumpWidgetAndSettle(const MyApp());
  await $(#email_input).enterText('test@example.com');
  await $(#submit_btn).tap();
  await $.pumpAndSettle();
  expect($(#home_screen), findsOneWidget);             // common: $(#key)/$(Text('text'))/.tap()/.enterText()/.scrollTo()
});
```

---

## flutter run in background + three-tier hot reload (change a line, send a signal)

**Precondition**: if the same device is occupied by another `flutter run` (e.g. VS Code debug), release it first — `ps aux | grep "flutter_tools.snapshot run" | grep -v grep`, if found, prompt the user to stop it before continuing, don't force-start.

**Launch**: the command **must start with `flutter run`** (if your permission rule matches by prefix like `Bash(flutter run:*)`, wrapping in nohup/pipe/`&` gets blocked); backgrounding relies on the `run_in_background: true` parameter; pass `--pid-file` (default `/tmp/flutter_app.pid`, for multi-device/session concurrency append a project or device suffix to avoid collision).

```bash
flutter run -d <deviceId> --target <entry> --pid-file=<PID_FILE> <dart-defines read from project CLAUDE.md>
```

**Wait for build** (a long-running process doesn't notify completion on its own, start a separate background Bash to poll):
```bash
until grep -qE "Flutter run key commands|FAILURE:|Gradle task .* failed|Error launching" <output>; do sleep 3; done
```

**Three-tier hot reload iron law** (launch must carry `--pid-file`, otherwise you can't send signals, and cold-starting per line wastes tens of minutes):

| What you changed | Which tier |
|---|---|
| UI/style/method body/ordinary logic | **① hot reload** `kill -USR1 $(cat <PID_FILE>)` (injects new code, preserves state) |
| Field initializer / `main()` / DI registration / route table / **initial state of an already-instantiated controller·singleton** / global variable | **② hot restart** `kill -USR2` (clears state, re-runs main, reuses compiled artifacts, faster than cold-start) |
| `android/`·`ios/` native / `pubspec.yaml` (add/remove deps·assets) / a new plugin with native code / engine·channel | **③ cold-start** (stop and re-`flutter run`) |

Mnemonic: Dart method body → USR1; initialization/registration/main/routes → USR2; touch native/pubspec/plugin → cold-start; **when unsure, USR2 first** (still faster than cold-start).

---

## Teardown/cleanup (kill flutter run ≠ closing the app) + anti cross-talk

**Anti cross-talk**: the same device can host multiple co-existing apps (different applicationId/bundleId, not overwriting each other). Before screenshot/tap confirm foreground = target package: `mobilecli apps foreground --device <id>` (or Android `adb ... dumpsys activity activities | grep mResumedActivity`); before reading logs identify the target app's PID (every Flutter app's `I/flutter` goes into logcat).

**Two teardown steps + re-check** (`kill flutter run` only severs the host, the device app keeps running):
```bash
kill "$(cat <PID_FILE>)" 2>/dev/null                      # 1) stop the flutter run host
mobilecli apps terminate --device <id> <packageName>      # 2) actually close the app (Android=am force-stop / iOS=simctl terminate, mobilecli has smoothed this over)
# 3) also terminate leftover apps from other projects on the same device; re-check foreground to confirm it's not a leftover app
```
**Before declaring "tested/stopped" re-check the real state with an independent command**, don't treat "I ran kill" as "the app is closed". **Device system state you changed during testing must likewise be restored + re-checked** — if you cut the network, verify it is back (`svc wifi enable` can wedge on some devices; see `references/android.md` §10 for the reliable recovery path).

---

## Platform details, advanced topics & portability

- **iOS parity** → `references/ios.md` (`xcrun simctl` simulator first / WebDriverAgent real device / go-ios / device trust·provisioning / teardown terminate)
- **Android details** → `references/android.md` (adb path/wm size/dumpsys/logcat/network-cut testing & recovery, platform last resort)
- **Offline test layer** → `references/offline-test-layer.md` (four fixture strategies)
- **Tool selection** → `references/tool-decision-tree.md` (when to use mobilecli/mobile-mcp/mobilewright/Patrol)
- **Scaling / unattended** → `references/scaling.md` (trust ladder, worktree/sub-agent/workflow parallelism, /schedule·/loop)
- **Project rollout**: `templates/` (CLAUDE.md constitution template + `.claude/settings.json` permission allowlist + format/analyze hook + `.claude/commands/{spec,verify,ship,debug,nightly}.md`). One-shot install: `bash setup-project.sh <project root>` (see README).

---

## Rules — hard-principle checklist (don't drop a single one; the mechanics live in their own sections, this is only for checking)

**Always**
1. Bootstrap the environment first; anything in the **green zone**, finish it yourself and keep going (§2).
2. Before interacting, `dump ui` to inspect, locate by Key/label, take coordinates from the rect center.
3. Double-tag interactive/assertable widgets with `Key` + `Semantics`; if `dump ui` won't list it = go back and fix the code.
4. Prove offline first with `flutter test` whatever can be proven offline; use logs, not screenshots, for whatever logs can prove.
5. Change code via `--pid-file` + `USR1`/`USR2`, don't cold-start.
6. Teardown closes the app in two steps and **re-checks to confirm**; **don't verify, don't report done**.
7. Assertion fail = logic bug, fix the implementation, don't change the test; self-fix **≤5 rounds** (round 3 note tried directions, round 4 switch approach, round 5 stop and emit a stuck report, continue to the next task).
8. Emit the report with all five **completion bar** items; missing any one means not done.
9. Commit per the user's commit policy (§1), never auto-commit by default.

**Never — the four red lines** (denied by default; the only unlock is explicit upfront user authorization with the scope stated; see §2): ① device physically disconnected (stop only after one self-recovery attempt) ② real-money operations ③ secret/credential operations ④ irreversible destruction, plus the project-specific red lines from the project `CLAUDE.md`. When not authorized: interactive may ask once, unattended skips and marks "authorization needed" — never hang waiting.

**Never — anti-patterns**: blind-tap when Semantics exists / hardcoding historical coordinates / treating `kill flutter run` as closing the app / changing the test to bypass an assertion / treating "I ran the operation" as "I achieved the result".

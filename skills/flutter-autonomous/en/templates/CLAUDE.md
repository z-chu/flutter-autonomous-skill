# {{APP_NAME}} — Project Constitution (On-Device / Automated-Testing Implementation Checklist)

> For the on-device run / automated-testing methodology see the global `flutter-autonomous` skill; this file holds only project-specific values and the implementation checklist.
> Don't restate the tool matrix / element-driven approach / verification layers / the 6 conventions — those live in the skill, and changing them here would only contradict the skill.

---

## Project Info (placeholders, in `{{...}}` for easy bulk `sed` replacement)

| Key | Value | Source/Notes |
|---|---|---|
| App name | `{{APP_NAME}}` | |
| Android applicationId | `{{ANDROID_APPLICATION_ID}}` | Same as `applicationId` in `android/app/build.gradle(.kts)`; used for `apps launch/foreground/terminate` |
| iOS Bundle ID | `{{IOS_BUNDLE_ID}}` | Same as `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj/project.pbxproj` |
| Dart package | `{{DART_PACKAGE}}` | `name:` in `pubspec.yaml`; Patrol/import use `package:{{DART_PACKAGE}}/...`; crash stacks key off this line |
| Entry point | `{{ENTRY_POINT}}` | Defaults to `lib/main.dart`; used by `flutter run --target` / Patrol |
| dart-defines | `{{DART_DEFINES}}` | Like `--dart-define=APP_ENV=debug`; if none, leave empty and delete the corresponding line in the command |
| env file | `{{ENV_FILE}}` | Like `.env.json`, paired with `--dart-define-from-file`; delete if none |
| pid-file | `{{PID_FILE}}` | Defaults to `/tmp/flutter_app.pid`; for concurrent multi-device/multi-session runs, append a project or device suffix to avoid collisions |

> If any item is missing, auto-detect and fill it per the skill's "Gather context before starting"; **don't hardcode, don't ask the user**.

---

## Devices (resolved dynamically at runtime, never hardcoded)

The device id **never goes into any file** — resolve it live each run:

```bash
mobilecli devices            # preferred, unified across iOS/Android; take .data.devices[0].id or filter by name
flutter devices              # fallback; includes simulators/physical devices
# Android fallback adb devices; iOS simulator xcrun simctl list devices booted
```

**Prefer a physical device**; if the physical device is offline, fall back to a simulator and note it in the report. Physical resolution is likewise resolved at runtime (the rect returned by `mobilecli` / `dump ui` is already in device physical pixels — **use it directly, no conversion needed**; conversion is only needed when measuring coordinates from a screenshot). If you really must hardcode, leave it optional here:

```
{{DEVICE_RESOLUTION}}        # optional, e.g. Android 1080x2400 / iOS 1179x2556; empty = resolve at runtime
```

---

## Log Anchors (grep these to verify features — harder evidence than screenshots)

`{{LOG_ANCHORS}}` — fill in this project's distinctive keywords, grep them when verifying "connection / state machine / key flows":

```
# WS/long-connection established:   {{LOG_ANCHORS}}
# WS/long-connection dropped:       {{LOG_ANCHORS}}
# State transition:                 {{LOG_ANCHORS}}
# Key business flow:                {{LOG_ANCHORS}}
# Layout overflow (generic):        RenderFlex overflowed   ← carries file:line, locates the overflow
```

How to capture (platform details in the skill's `references/{android,ios}.md`): `adb logcat -s flutter -d | tail -200` (Android) / `flutter logs` (generic) / iOS simulator `xcrun simctl spawn <udid> log stream`. On the same device, `I/flutter` from every Flutter App lands in logcat, so **identify the target App's PID first** before reading.

---

## Toolchain Constraints

`{{TOOLCHAIN}}` — this project's hard requirements on build-tool versions (failing them breaks the build / signing):

```
JDK:      {{TOOLCHAIN}}    # e.g. JDK17, the version bound to Gradle and AGP
Xcode:    {{TOOLCHAIN}}    # minimum Xcode / CLT version for iOS
Gradle:   {{TOOLCHAIN}}    # e.g. the wrapper-locked version
Other:    {{TOOLCHAIN}}    # NDK / CocoaPods / Flutter channel, etc.
```

---

## Coexisting Apps on the Same Device (for cross-talk prevention / teardown)

`{{COEXISTING_APP_IDS}}` — package names of **other projects** that coexist long-term on the same device (different applicationId/bundleId, no mutual overwrite).
Purpose: (1) before screenshot/tap, confirm the foreground isn't them; (2) at teardown, also `apps terminate` these leftover Apps, then re-check the foreground isn't a leftover:

```
{{COEXISTING_APP_IDS}}       # e.g. com.other.app, com.demo.sandbox; if none, write "none"
```

---

## Sensitive Data (screenshot redaction, optional)

`{{SENSITIVE_DATA_NOTE}}` — if the device/account contains sensitive info (balances, private content, personal identity, etc.), write the redaction requirements here: mask before screenshots / switch to a redacted environment / don't commit. If no sensitive data, write "none".

```
{{SENSITIVE_DATA_NOTE}}
```

---

## Project-Specific Irreversible / Red Lines (denied by default, don't act on your own)

`{{IRREVERSIBLE_REDLINES}}` — beyond the skill's four red lines (device physically offline / real-money operations / secret or credential operations / irreversible destruction), the red-line actions **specific to this project**. Red lines are never done by default: an interactive session may pause and ask once; an unattended run skips the item, marks "authorization needed" in the report, and continues:

```
{{IRREVERSIBLE_REDLINES}}    # fill per your app's domain. e-commerce: real orders/payments/refunds; social: messaging real users/publishing; blockchain: on-chain transactions/private keys or mnemonics; generic: changing production config/deleting user data
```

### Authorized Red-Line Exceptions (all denied by default — only what you write here may be done)

`{{AUTHORIZED_REDLINE_EXCEPTIONS}}` — red-line operations (real money / secrets & credentials / irreversible) are **never done by default**; only what you explicitly allow here (or in this run's instructions) will be performed, and only within the stated scope:

```
{{AUTHORIZED_REDLINE_EXCEPTIONS}}   # e.g. "sandbox environment may place real orders/payments", "testnet (devnet) transactions allowed", "test-account data may be wiped"; if everything is forbidden, write "none"
```

---

## Definition of Done (DoD) — the offline layer is the first gate

Pass the gates in order, **don't move to the next gate until the previous one is green** (to save device time):

1. [ ] **Offline fixtures green**: `flutter test` (pure logic/parsing/state machine verified in seconds with fixtures+mocks, no device)
2. [ ] **Zero static warnings**: `flutter analyze` with zero error / zero warning
3. [ ] **Target-device Patrol all green**: `patrol test -t integration_test/<feature>_test.dart --device <id resolved at runtime>`
4. [ ] **Screenshot visual confirmation**: after `mobilecli screenshot`, Read and verify — no overflow/misalignment/blank
5. [ ] **Handle per the commit policy** (see "Commit Policy" below, `{{COMMIT_POLICY}}`: commit incrementally / commit at the end / don't commit — if "don't commit" is chosen, skip this gate)

> Don't put logic that can be proven offline on a real device; don't rely on screenshots alone for what logs (connection/state machine) can prove. Layer details in the skill's "four verification layers".

---

## Commit Policy (you decide; the skill won't decide for you and won't auto-commit by default)

`{{COMMIT_POLICY}}` — fill in how you want the AI to commit on this project; the AI follows this before starting work (if left blank, it asks first):

```
{{COMMIT_POLICY}}    # pick one/customize: (1) commit a bit as you go (2) commit everything at the end (3) don't commit (edit only, you commit by hand) (4) other requirements
```

If you choose "commit", the commit conventions (conventional prefixes feat/fix, precise `git add <file>` not `git add .`, whether to push, wrap messages containing backticks / `$` / `!` in single quotes or use `-F`, **never add an AI signature**) follow the global `CLAUDE.md` or are overridden here.

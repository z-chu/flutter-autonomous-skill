# iOS Parity Guide (simulator first → WebDriverAgent on real devices)

> This doc is the iOS-platform expansion of the keystone (`../SKILL.md`). Terminology, hard principles, the loop order, the Key+Semantics dual standard, the four verification layers, kill≠force-stop, self-repair ≤5 rounds, commit conventions — **the keystone is authoritative; this doc does not restate them**, it only fills in the iOS-specific landing differences.
> Placeholders: `<udid>` (UDID of the simulator/real device), `<bundleId>` (app bundle identifier — read it from the project `CLAUDE.md` or the `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj/project.pbxproj`, **never hard-code it**), `<deviceId>` (the device id from mobilecli's perspective; for a simulator it's the UDID), `<deeplink>`.
> **Platform prerequisite: the iOS toolchain exists only on macOS. When running this automation on Linux you can only run Android; the iOS parts are skipped wholesale (see the end of this doc). The simulator is mac-exclusive.**

---

## 0. Two paths, simulator first

iOS has two distinct chains; **default to the simulator first**:

| | Simulator | Real Device |
|---|---|---|
| Trust barrier | **Zero** — `xcrun simctl` drives it directly, no signing/pairing/trust needed | Needs device pairing trust + Developer Mode + WDA re-signing (provisioning profile) |
| CI friendliness | High — pure command line, can boot and shut down | Low — depends on a physical device + USB + certificates |
| Interaction base | WDA (mobilecli/mobile-mcp auto-launch WDA inside the simulator) | WDA (via USB tunnel + port forwarding) |
| Use case | **iOS default verification target**: UI/navigation/screenshots/Patrol regression | Only what a real device can verify: camera, real push, performance, specific hardware, biometrics |

**Conclusion: unless the task explicitly calls for a real-device capability, always pick the simulator.** It's zero-trust, scriptable to start/stop, and runs on CI. A real device is "extra cost paid only when necessary."

iOS vs Android correspondence (keystone interaction conventions are identical on both ends; only the base commands differ):

| Concept | Android | iOS |
|---|---|---|
| Device identifier | serial (`adb devices`) | UDID (`<udid>`) |
| Bundle identifier | applicationId (package name) | `<bundleId>` |
| Launch | `am start` / adb | `xcrun simctl launch` or mobilecli |
| Terminate | `am force-stop` | `xcrun simctl terminate` or `mobilecli apps terminate` (**not** force-stop) |
| Logs | `adb logcat -s flutter` | `xcrun simctl spawn <udid> log stream` (simulator) |
| Hard keys BACK/DPAD | Yes | **No** (use gestures / nav-bar tap) |
| Arbitrary-path filesystem | Yes (`fs ls/push/pull`) | **No** (only `apps path` to get the container path) |
| Clear app data | `apps clear` / `pm clear` | **Unsupported** (real device; simulator requires uninstall+reinstall or erase) |

---

## 1. Simulator chain (default)

### 1.1 Start/stop (two equivalent sets, pick by the tools at hand)

```bash
# List installed simulators (incl. UDID, state)
xcrun simctl list devices            # all
xcrun simctl list devices booted     # only booted (use this one for bootstrap health checks)

# Boot / shut down a simulator
xcrun simctl boot <udid>             # or mobilecli device boot --device <udid>
xcrun simctl shutdown <udid>         # or mobilecli device shutdown --device <udid>
open -a Simulator                    # optional: pop up the Simulator window for eyeball observation
```

mobilecli's `device boot/shutdown` is equivalent to `simctl boot/shutdown` — **if you have mobilecli, use mobilecli; it unifies the commands across iOS/Android**; bare `simctl` is the low-level fallback. `mobilecli devices` also lists booted simulators (`platform:ios, type:simulator, state:online`).

### 1.2 Install / launch / terminate the App

```bash
# Install (the simulator takes a .app directory, or a .zip containing a .app; mobilecli auto-unzips .zip)
xcrun simctl install <udid> /path/to/Runner.app
mobilecli apps install /path/to/build.zip --device <udid>   # .zip contains the .app

# Launch / terminate
xcrun simctl launch    <udid> <bundleId>
xcrun simctl terminate <udid> <bundleId>
# Equivalent (recommended, unified cross-platform):
mobilecli apps launch    <bundleId> --device <udid>
mobilecli apps terminate <bundleId> --device <udid>

# Deep-link jump (skip step-by-step navigation, go straight to the page)
xcrun simctl openurl <udid> "<deeplink>"
mobilecli device url "<deeplink>" --device <udid>
```

> Flutter usually does `flutter run -d <udid>` directly, which auto-builds + installs + launches; the simctl commands above are for "you already have an artifact and want to install/launch/terminate it standalone" or for teardown.

### 1.3 Screenshots and logs

```bash
# Screenshot (Read to verify after it lands on disk)
xcrun simctl io <udid> screenshot /path/shot.png
mobilecli screenshot --device <udid> -o /path/shot.png      # equivalent

# Log stream (the "logs" layer of the four verification layers — the hardest evidence for connection/state-machine/gating)
xcrun simctl spawn <udid> log stream --level debug --predicate 'processImagePath CONTAINS "Runner"'
# Flutter's print/debugPrint can also go through `flutter logs` (unified cross-platform)
```

### 1.4 WDA auto-launch on the simulator

Simulator interactions (tap/swipe/text/dump) all go through **WebDriverAgent** (listening on `localhost:8100`). mobilecli `agent install` auto-installs WDA into the simulator; mobile-mcp launches WDA via `xcrun simctl launch <udid> com.facebook.WebDriverAgentRunner.xctrunner` and polls `GET localhost:8100/status` until `value.ready==true`. **The simulator needs no provisioning profile** (re-signing is only required on real devices).

---

## 2. Real-device chain (needs trust + signing)

Real-device interactions **all go through WebDriverAgent** (`localhost:8100`). mobilecli auto-launches WDA + port forwarding + USB tunnel; the bare chain (mobile-mcp) requires you to set up the tunnel yourself with go-ios.

### 2.1 The four things to get a device ready

1. **Pairing trust (usbmux)**: after connecting over USB, the device pops "Trust This Computer" on first connection — tap Trust.
2. **Developer Mode (iOS 16+)**: turn on `Settings > Privacy & Security > Developer Mode` and restart the device. Otherwise WDA won't install and debugging won't start.
3. **Tunnel (iOS 17+)**: from iOS 17 a tunnel is required to connect to WDA. mobilecli launches it automatically; mobile-mcp needs go-ios to start the tunnel, listening on port **60105**.
4. **Port forwarding**: WDA's 8100 is forwarded to local `localhost:8100`. mobilecli does it automatically; the bare chain has go-ios do it.

### 2.2 mobilecli real device: install WDA (needs a provisioning profile)

WDA on a real device must be **re-signed with a valid Apple provisioning profile** (the simulator doesn't need it):

```bash
mobilecli agent status  --device <udid>           # first check whether WDA is installed
mobilecli agent install --device <udid> --provisioning-profile /path/to/x.mobileprovision
mobilecli agent install --device <udid> --provisioning-profile /path/to/x.mobileprovision --force   # force reinstall
```

**Provisioning profile shortcut**: you don't need a dedicated WDA profile. **The app's own `embedded.mobileprovision` works** — mobilecli uses it to re-sign the WDA agent:

```bash
# the embedded.mobileprovision from the Flutter project's debug build (available after one build)
mobilecli agent install \
  --device <udid> \
  --provisioning-profile build/ios/Debug-iphoneos/Runner.app/embedded.mobileprovision
```

> If the debug build artifact doesn't exist yet, run `flutter build ios --debug` once, or Run once from Xcode to let it sign; after the artifact lands in `build/ios/Debug-iphoneos/Runner.app/`, install the agent.

Once installed, commands like `io tap` / `dump ui` / `screenshot` are **exactly the same** as on the simulator — the difference has been smoothed over by mobilecli.

> ⚠️ **`agent install` pushes the app under test into the background** (the agent is itself a UITest runner, so the device/simulator returns to the home screen once it's installed). Don't `dump ui` straight afterwards — the foreground is no longer your app. **`apps launch` to bring it back, `apps foreground` to confirm, then dump** (the usual anti-cross-talk routine).
>
> The same applies on the simulator: when `dump ui` reports `agent is not installed, use 'mobilecli agent install'`, run `mobilecli agent install --device <udid>` (no provisioning profile needed on a simulator), then relaunch the app.

**⚠️ Real-device screenshot speed**: on a real iOS device, each screenshot via WDA over the USB tunnel takes about **15–20 seconds** (longer on the first one, including WDA cold start) — this is normal. Reduce screenshot frequency — prefer `dump ui` to judge page state, and only take screenshots when necessary (verifying navigation, checking visual layout).

### 2.3 mobile-mcp real device: additionally needs go-ios + tunnel + WDA

If you go through mobile-mcp (instead of mobilecli), a real device additionally needs:

```bash
npm i -g go-ios            # provides the `ios` command; mobile-mcp uses it to discover/drive real devices
ios list                   # list real-device UDIDs (without go-ios installed, no physical device is discovered)
ios info --udid <udid>     # get ProductVersion etc.; iOS 17+ determination needs a tunnel
```

mobile-mcp's readiness check chain (it reports whichever step is missing — check yourself against this):
- **Tunnel**: required on iOS 17+, listens on `localhost:60105`; not reachable → start the tunnel.
- **Port forwarding**: `localhost:8100` not reachable → WDA's port isn't forwarded.
- **WDA running**: `GET localhost:8100/status` not `ready:true` → WDA isn't running on the device.

> The `GO_IOS_PATH` environment variable can specify the go-ios binary path; if unset, the `ios` on PATH is used.

---

## 3. Element-driven interaction: iOS and Android share the same conventions

The keystone's "inspect first → tap the rect center by label" is **unchanged** on iOS: the base is still mobilecli `dump ui` → `io tap`, only that on iOS the page source is fetched via WDA.

```bash
D=<udid>                                               # get it from mobilecli devices, don't hard-code
mobilecli apps launch     <bundleId> --device "$D"     # bring to foreground
mobilecli apps foreground --device "$D"                # confirm foreground = target bundle (cross-talk guard)
mobilecli dump ui         --device "$D" > "$UI"        # fetch elements via WDA: label/name + on-screen rect (⚠️ don't add 2>&1)
# pick the target by label, tap the rect center:
mobilecli io tap   --device "$D" <cx>,<cy>
mobilecli io swipe --device "$D" x1,y1,x2,y2
mobilecli io text  --device "$D" "text"
mobilecli screenshot --device "$D" -o "$SHOT"          # → Read to verify
```

`scripts/tap-by-label.sh <deviceId> "<label substring>"` (provided by the keystone) works on iOS too — internally `dump ui` → jq picks the rect center by label → `io tap`.

> **iOS stderr logs**: when a real iOS device runs via the WDA/USB tunnel, `mobilecli` prints a lot of `INFO connect to lockdown...` logs to **stderr**. These go to stderr, not stdout, so `dump ui > "$UI"` yields clean JSON. **Note**: if you write `dump ui > "$UI" 2>&1` (merging stderr into the file), the logs pollute the JSON and break parsing. Adding `2>/dev/null` silences terminal noise but is not required. Android has no such issue.

### 3.1 WDA element-filtering rules → why Flutter widgets still need to expose Semantics

After WDA fetches the device's accessibility tree, it **only keeps** elements that satisfy both of these:
1. **Type is in the allowlist**: `TextField`, `Button`, `Switch`, `Icon`, `SearchField`, `StaticText`, `Image`.
2. **Visible** (`isVisible==1` and the rect's x/y ≥ 0) **and** has at least one of `label` / `name` / `rawIdentifier`.

**Meaning (fully consistent with the keystone's Key+Semantics dual standard)**: Flutter paints on a canvas; when a widget doesn't expose `Semantics` it has neither a label/name nor gets mapped to a recognizable type like Button/TextField → **`dump ui` can't list it**. So the iron rule on iOS is the same as on Android:

- Standard `Text`/`ElevatedButton`/`TextField` carry recognizable semantics out of the box;
- **Custom gesture widgets (`GestureDetector`/`InkWell`/`Touchable`) must be explicitly wrapped in `Semantics(label: ..., button: true)`**, otherwise they're filtered out by WDA and won't be listed;
- `dump ui` can't list your widget = no Semantics exposed → **go back to the code and add it**, don't downgrade to blind-tap coordinates.

> `Semantics(button: true)` helps the widget be mapped to the `Button` type (hits the allowlist), and `label` provides a readable name (hits "has at least a label/name") — both together make it reliably tappable.

---

### 3.2 Determinism switches (simulator only; the precondition for comparable screenshots/goldens)

A simulator lets you pin down the system chrome that would otherwise differ on every run, which is what makes screenshots comparable to each other and to a baseline. **These are all reversible simulator state — green zone — but they still must be cleared at teardown.**

```bash
# Pin the status bar: fixed time/signal/battery, otherwise every screenshot's status bar differs
xcrun simctl status_bar <udid> override --time "9:41" --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl status_bar <udid> list      # re-check the current override
xcrun simctl status_bar <udid> clear     # teardown: clear it

# System-level light/dark
xcrun simctl ui <udid> appearance dark|light
xcrun simctl ui <udid> appearance        # no argument = read the current value (read before changing, to restore later)

# Record video as evidence (leaves a reviewable trace of an unattended run)
xcrun simctl io <udid> recordVideo --codec h264 /path/run.mov   # Ctrl-C to stop
```

Key points:

- **The status-bar override is the precondition for visual verification / golden comparison on iOS**: without pinning the time and signal, two screenshots always differ and the diff is all noise.
- **For dark-mode verification, prefer `brightnessOverride` from `vm-service.md` §3.5** — it affects only the app itself, dies on restart, and needs no restoring; `simctl ui appearance` changes the whole simulator's state, so **read the original value before changing it and write it back at teardown**.
- **Real devices have none of this**: `status_bar override` / `ui appearance` are simulator-only. Visual verification on a real device must either accept status-bar differences or crop the status bar before comparing.
- The recording isn't for the AI (it can't read video) — it's evidence for a **human** to review in the morning. To let the AI see the middle of the run, extract frames with `ffmpeg -i run.mov -vf fps=1 frame_%03d.png` and Read a few.

**The iOS log window** (the counterpart of `android.md` §4.1 — slice the log into per-action windows, then assert):

```bash
# Long-running stream (start it in a separate background Bash; don't block the main thread)
xcrun simctl spawn <udid> log stream --style json \
  --predicate 'processImagePath CONTAINS "Runner"' > win.log
# Or: look back at the last stretch after performing an action (no long-running process)
xcrun simctl spawn <udid> log show --last 30s --style json \
  --predicate 'processImagePath CONTAINS "Runner"' > win.log
```

`--style json` produces a machine-readable structure, more robust than parsing human-readable logs; have the app emit single-line JSON anchors with `dev.log('{"evt":...}', name: 'e2e')` and assert with jq.

---

## 4. iOS vs Android capability differences (avoid using the wrong command)

| Capability | iOS real device/simulator | Alternative |
|---|---|---|
| Arbitrary-path filesystem (`fs ls/push/pull/mkdir/rm`) | **Unsupported** | Only `mobilecli apps path <bundleId>` to get the container path; to read files inside the container, go through Xcode/Devices or the simulator's `~/Library/Developer/CoreSimulator/.../data` |
| Clear app data (`apps clear`) | **Unsupported** (OpenRPC is explicit: not supported on real devices; the simulator needs uninstall+reinstall or `xcrun simctl erase`) | Uninstall+reinstall: `apps uninstall` → `apps install`; or simulator `xcrun simctl erase <udid>` |
| Hard keys `BACK` / `DPAD_*` | **None** (these are Android only) | Use a gesture to go back (swipe right from the left screen edge) / tap the nav-bar back button (first `dump ui` to find the back widget, then tap) |
| Hard keys `HOME` / `VOLUME_UP` / `VOLUME_DOWN` | Yes (WDA supports home/volumeup/volumedown) | `mobilecli io button --device <udid> HOME` |
| `ENTER` (submit input) | Send `\n` via WDA | include a newline in `io text`, or `io button ENTER` |
| Screen video stream | **mjpeg only** (`screencapture --format mjpeg`; avc/H.264 is Android only) | `mobilecli screencapture --device <udid> --format mjpeg \| ffplay -` |

| Changing permission grant state (`xcrun simctl privacy grant/revoke`) | **Often `Operation not permitted`** (blocked by macOS's own permissions, not a malformed command) | To get back to "not determined": `apps uninstall` → `apps install`. To toggle a specific permission: open the Settings page and tap the switch with element-driven interaction (Settings is native, so its controls carry accessibility labels) |

Mnemonic: **on iOS don't send BACK/DPAD, don't use fs arbitrary paths, don't apps clear, don't request avc for screencapture, don't expect simctl privacy to change grants** — any of these errors or no-ops on send, wasting a self-repair round.

---

## 5. Flutter assertions still go through Patrol (unchanged)

The keystone's "use Patrol for repeatable Flutter assertions (Dart VM, by Key)" is on iOS **likewise the only stable deterministic-assertion path**, supported on both simulator and real device:

```bash
patrol test -t integration_test/<feature>_test.dart --device <udid> [--timeout 300]
```

Patrol connects directly to the widget tree via the Dart VM and finds+asserts by `Key`, **not depending on the WDA accessibility-tree exposure** — so even if a widget doesn't expose Semantics and `dump ui` can't list it, Patrol can still hit it by `Key`. The two paths each eat the same thing: `Key` for Patrol, `Semantics(label:)` for element-driven — **add both** (see the keystone code contract).

> **mobilewright does not officially support Flutter ⏳** (consistent with the keystone tool decision tree). Deterministic regression assertions for Flutter on iOS **use only Patrol**; don't expect mobilewright's `getByLabel().tap()` to hit Flutter widgets.

---

## 6. Bootstrap iOS checklist (if missing, install/start it yourself, don't stop for a human)

When entering autonomous mode, first run these health checks; they correspond to the keystone §2 "detect → install if missing → verify with an independent command." **Installing tools / booting the simulator / installing WDA are all green zone — do it yourself and keep going** — only the keystone's four red lines stop you or need authorization.

| Check | Command | Expected / what to do if missing |
|---|---|---|
| Xcode CLT present | `xcode-select -p` | Outputs a path (e.g. `/Applications/Xcode.app/...` or `/Library/Developer/CommandLineTools`); empty/error → `xcode-select --install` (a GUI install means prompt the user; pre-install on CI) |
| A booted simulator exists | `xcrun simctl list devices booted` | Lists at least one `(Booted)`; empty → `xcrun simctl list devices` to pick one → `xcrun simctl boot <udid>` (or `mobilecli device boot`) |
| mobilecli sees the device | `mobilecli devices` | Contains `platform:ios`; empty and the simulator is already booted → wait a few seconds and retry |
| WDA running | `curl -s localhost:8100/status` | JSON contains `"ready":true`; not reachable → mobilecli `agent install --device <udid>` (add `--provisioning-profile` for a real device — **just use the app's own `build/ios/Debug-iphoneos/Runner.app/embedded.mobileprovision`, see §2.2**); the simulator auto-launches WDA |
| Real device: go-ios present (only for the mobile-mcp real-device path) | `which ios` && `ios version` | Has a path and the version starts with `v`; missing → `npm i -g go-ios` |
| Real device: tunnel (iOS 17+, when going through mobile-mcp) | `curl -s localhost:60105` or check the port listening | The port is listening; not reachable → start the tunnel with go-ios (mobilecli starts it automatically, no manual step) |

> One-shot cross-platform: `npx mobilewright doctor --json` covers Node/mobilecli/Xcode/Simulators/agent/Java/ADB (mentioned in keystone §2), then add `flutter doctor`, `patrol --version`.

---

## 7. Teardown/cleanup (kill ≠ close the App, iOS version)

Consistent with the keystone: `kill flutter run` only cuts the host process; the App on the device/simulator keeps running. **On iOS use terminate, not am force-stop** (force-stop is an Android concept; iOS has none).

```bash
kill "$(cat <PID_FILE>)" 2>/dev/null                       # 1) stop the flutter run host
mobilecli apps terminate <bundleId> --device <udid>        # 2) actually close the App
#    equivalent: xcrun simctl terminate <udid> <bundleId>
# 3) also terminate any other project's leftover App on the same device
mobilecli apps foreground --device <udid>                  # 4) check the foreground again, confirm it's not a leftover App
```

**Before declaring "tested/stopped", check the real state with an independent command** (`apps foreground` / `simctl list devices booted`); don't take "I ran terminate" as "the App is closed" — this is the keystone's "don't verify, don't report done" hard principle.

---

## 8. Linux / platform boundary (important)

- **There's no iOS toolchain on Linux**: no `xcrun`, no `simctl`, no simulator, and go-ios has no macOS private frameworks to back it — this entire doc is unusable on Linux. In a Linux environment the automation **only runs Android** (go through `references/android.md`); the iOS verification is skipped wholesale, and note "iOS skipped: not macOS" in the report.
- **The simulator is macOS-exclusive**: iOS Simulator can only run on a mac. Real-device debugging also needs a mac (re-signing WDA, the Xcode toolchain).
- Therefore in CI/unattended setups: only a mac runner runs iOS (simulator preferred); a Linux runner only takes on Android. Probe the environment first with `uname`/`xcode-select -p`; if not a mac, go straight to the Android branch.

# Android Platform Details (adb is the platform backend)

> Read the keystone `SKILL.md` first: the interaction base is unified on `mobilecli`, and **whenever `Semantics` is present always go element-driven** (`dump ui` → tap rect center); **adb blind-tap is the last resort** — only fall back to measuring coordinates for pure canvas with no Semantics. This doc only covers the deep details of the Android platform backend (adb); it does not restate the methodology.
>
> One-line positioning: **most Android features work with bare `adb`** (device discovery, foreground verification, logs, teardown, pixels); on Android `mobilecli` uses the `adb` path for discovery and tapping, and **only non-ASCII input requires installing an on-device agent**. Placeholders: `<id>` = device serial, `<applicationId>` = the package name of the App under test (read from the project `CLAUDE.md` or the `applicationId` in `android/app/build.gradle(.kts)`, never hardcode it).

---

## 1. adb Path Detection (find a usable adb before proceeding)

Probe by priority, use the first hit, and **never hardcode an absolute path**:

```bash
# Priority: env var > mac default SDK > Linux default SDK > fallback bare adb (on PATH)
adb_bin() {
  if [ -n "$ANDROID_HOME" ] && [ -x "$ANDROID_HOME/platform-tools/adb" ]; then
    echo "$ANDROID_HOME/platform-tools/adb"
  elif [ -n "$ANDROID_SDK_ROOT" ] && [ -x "$ANDROID_SDK_ROOT/platform-tools/adb" ]; then
    echo "$ANDROID_SDK_ROOT/platform-tools/adb"
  elif [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]; then   # mac default SDK location
    echo "$HOME/Library/Android/sdk/platform-tools/adb"
  elif [ -x "$HOME/Android/Sdk/platform-tools/adb" ]; then           # Linux default SDK location
    echo "$HOME/Android/Sdk/platform-tools/adb"
  else
    command -v adb || { echo "adb not found; install platform-tools or set ANDROID_HOME" >&2; return 1; }
  fi
}
ADB="$(adb_bin)"
```

- Try both env vars: newer projects mostly use `ANDROID_HOME`, older ones may only have `ANDROID_SDK_ROOT`.
- Fallback bare `adb`: the user may have installed platform-tools via Homebrew / a package manager, already on PATH.
- If you truly can't find it, this is **green zone** (keystone §2) — install platform-tools yourself, then re-verify with `"$ADB" --version`; don't stop and ask for manual help.

---

## 2. Device Discovery and One-Shot Self-Recovery

```bash
"$ADB" devices            # list online devices; only a line "<id>\tdevice" counts as ready
```

Decision and self-recovery (**recover only once**, aligned with the keystone red line "stop only on physical disconnect"):

- A `<id>\tdevice` in the list → ready, proceed.
- **Empty / header only / status is `offline` or `unauthorized`** → self-recover once with `"$ADB" kill-server && "$ADB" start-server`, then re-list.
- Still empty after recovery = **physically disconnected / not plugged in / debugging not authorized**; this is keystone red line #1 "device physically disconnected" — stop and report being stuck.
- `unauthorized`: there's an unclicked "Allow USB debugging" prompt on the device → this is physical-side manual work; prompt the user to confirm on the device, don't wait forever.
- Multiple devices coexisting: have all adb commands carry `-s <id>` to lock the target; fetch `<id>` at runtime from `"$ADB" devices`, and **never write it into any file**.

> mobilecli can also list devices (`mobilecli devices`, output is JSON for easy `jq` extraction of the id); underneath it's the same adb path. Pick either; in scripts, extracting the id from mobilecli's JSON saves parsing.

---

## 3. Cross-talk Prevention: Confirm Foreground = App Under Test

The same device can host multiple Flutter Apps (different `applicationId`, not overwriting each other). Before screenshot / tap / reading logs you **must confirm the foreground is the target package**, otherwise you'll be tapping around in another App while thinking you're testing your own.

```bash
# Package owning the foreground Activity: output must contain the target <applicationId>
"$ADB" -s <id> shell dumpsys activity activities | grep mResumedActivity
# Typical output: mResumedActivity: ActivityRecord{... <applicationId>/.MainActivity ...}
```

- Doesn't contain the target package = cross-talk → first run `mobilecli apps foreground --device <id>` or relaunch the target App, then continue.
- mobilecli equivalent: `mobilecli apps foreground --device <id>` returns the foreground package name directly, cleaner than grepping dumpsys — prefer it.

**Before reading logs, identify the target App's PID** — all Flutter Apps on the device send their `I/flutter` into the same logcat, and without filtering by PID you'll mistake another App's logs for your own:

```bash
PID="$("$ADB" -s <id> shell pidof <applicationId>)"   # empty = App not running
"$ADB" -s <id> logcat --pid="$PID"                    # see only all-process logs of the target App
```

---

## 4. Logs: Capture Connections / State Machine / Layout Overflow (the hardest evidence)

Flutter's `print`/`debugPrint` goes through the `I/flutter` tag:

```bash
"$ADB" -s <id> logcat -s flutter            # see only Flutter output
"$ADB" -s <id> logcat -c                    # clear old logs before running a case, to avoid reading leftovers from the prior round
```

Per the keystone "verification four layers · layer 4 evidence", grep key anchors (read the specific anchor strings from the project `CLAUDE.md`; below are generic shapes):

```bash
# Connection class: the URL of a connected WS/HTTP, handshake-success markers
"$ADB" -s <id> logcat -s flutter | grep -iE "ws://|wss://|connected|handshake"
# State machine: state-name transitions (confirms it reached the expected state, more reliable than a screenshot)
"$ADB" -s <id> logcat -s flutter | grep -iE "state|status"
# Layout overflow: carries file:line, directly pinpoints the offending widget
"$ADB" -s <id> logcat -s flutter | grep -iE "RenderFlex overflowed|overflowed by .* pixels"
```

- For long-running log watching, start a separate background Bash poll; don't block the main thread (see the keystone `until grep` pattern).
- For "did it happen or not" judgments like connection/state/gating, **use logs, not screenshots** — screenshots only prove visuals/layout.

---

## 4.1 Assert against a "log window" (harder than grepping everything)

The problem with grepping the whole `logcat` is that you can't tell whether a line came from *this* step or is left over from the previous one. **Slice the log into windows, one per action** — only then does the assertion hold:

```bash
"$ADB" -s <id> logcat -c                                   # 1) clear the buffer: this marks the window start
mobilecli io tap --device <id> <cx>,<cy>                   # 2) perform 【one】 action
sleep 1
"$ADB" -s <id> logcat -d --pid="$PID" -s flutter > win.log # 3) take only this step's log
grep -qE "<expected anchor>" win.log && echo PASS || echo FAIL   # 4) assert against the window
```

- `-d` dumps and exits (not long-running); combined with `-c` it gives you a clean window.
- `--pid="$PID"` prevents cross-talk (§3); use them together.
- **Have the app emit machine-readable anchors**, so assertions don't have to regex human-readable text:

  ```dart
  dev.log('{"evt":"order_submitted","id":"$id"}', name: 'e2e');   // dart:developer
  ```

  On the assertion side: `grep -o '{.*}' win.log | jq -e 'select(.evt=="order_submitted")'`. The anchor strings themselves belong in the project `CLAUDE.md`.
- **A harder error assertion** is in `vm-service.md` §4: `errorsSinceReload` covers every error type at once, so you don't write one grep per error kind.

---

## 4.2 Determinism switches: kill animations before screenshotting/tapping

Screenshots and taps both drift while animations are running — the number-one source of device-layer flake. **Turn off system animations before running cases** (reversible, green zone):

```bash
for k in window_animation_scale transition_animation_scale animator_duration_scale; do
  "$ADB" -s <id> shell settings put global $k 0
done
```

**You must restore and re-check at teardown** (same severity as the §10 network cut — leaving the user's device with no animations is a teardown incident):

```bash
"$ADB" -s <id> shell settings put global window_animation_scale 1.0
"$ADB" -s <id> shell settings put global transition_animation_scale 1.0
"$ADB" -s <id> shell settings delete global animator_duration_scale   # this one may be unset by default
"$ADB" -s <id> shell settings get global window_animation_scale       # re-check: confirm it's restored
```

> **Read the original value before changing a setting**, and write that value back on restore — don't assume the default is 1.0. Measured: on some models `animator_duration_scale` is unset (`null`) to begin with, and those need `settings delete` rather than writing 1.0.

Other controllable determinism / scenario switches (also restore + re-check when done):

```bash
"$ADB" -s <id> shell settings put system font_scale 1.3           # layout verification at large font scale
"$ADB" -s <id> shell cmd uimode night yes|no                      # system-level dark mode
"$ADB" -s <id> shell pm grant|revoke <applicationId> <permission> # deterministic setup for permission flows
```

> For dark-mode verification, prefer `brightnessOverride` from `vm-service.md` §3.5 — **no system setting changed, nothing to restore** — cleaner than `cmd uimode`.

---

## 4.3 Quantified metrics: startup time and jank (assertable numbers)

Beyond visuals and interaction there's one more dimension: **performance can be part of the acceptance criteria**, and it's numeric — no human judgment needed.

```bash
# Cold-start time: measure after a force-stop; TotalTime is the assertable millisecond figure
"$ADB" -s <id> shell am force-stop <applicationId>
"$ADB" -s <id> shell am start -W -n <applicationId>/.MainActivity | grep -E "TotalTime|LaunchState"
# → LaunchState: COLD / TotalTime: 1725

# Jank: read after running an interaction; gives the janky ratio and percentiles
"$ADB" -s <id> shell dumpsys gfxinfo <applicationId> reset      # zero it first
# …perform the interaction under test…
"$ADB" -s <id> shell dumpsys gfxinfo <applicationId> \
  | grep -E "Total frames|Janky frames|90th|95th|99th"
# → Janky frames: 1 (33.33%) / 90th percentile: 109ms
```

- `dumpsys gfxinfo` statistics are **cumulative**; without a `reset` first you're reading a mix going back to boot, and the assertion is meaningless.
- How to use it: write "first-screen TotalTime < X ms" and "janky ratio < Y%" into the acceptance criteria, and the autonomous loop can judge pass/fail on its own — far more actionable than "feels a bit laggy". Thresholds are project-specific: put them in the project `CLAUDE.md`.
- For a deeper timeline, use `flutter run --profile --trace-to-file=<path>` (Perfetto proto format).

---

## 4.4 Input methods: disable every IME before typing, read the text back afterwards

While you type, the on-screen IME panel does two bad things at once: it **covers the element under test**, and it **puts its own candidates/keys into `dump ui`**, so "find the element by label" picks the keyboard instead of your app's widget. So disable the input methods before typing (reversible, green zone).

**Disabling only the default one (Gboard, say) is not enough** — once it's off, the system lets **voice input** take over, and you get a panel anyway. Take the disable list from `ime list -a -s` (`-a` = all, including already-disabled ones) so nothing slips through:

```bash
# Record the original values first: "which ones were enabled" and "which was the default" are two independent facts
"$ADB" -s <id> shell ime list -s | tr -d '\r' | sed '/^$/d' > /tmp/imes_enabled.txt
"$ADB" -s <id> shell settings get secure default_input_method | tr -d '\r' > /tmp/ime_default.txt
# Disable them all: the list comes from -a (includes already-disabled), so the voice input that would take over is covered
"$ADB" -s <id> shell ime list -a -s | tr -d '\r' | sed '/^$/d' | while IFS= read -r i; do
  "$ADB" -s <id> shell ime disable "$i" >/dev/null 2>&1
done
"$ADB" -s <id> shell ime list -s        # re-check: empty output = really all disabled
```

**Restore + re-check at teardown** (same severity as §4.2's animations and §10's network cut — leaving the user's device with no input method is a teardown incident): `enable` only **the ones that were originally enabled**, and write the default back to **the one it originally was**, not the first line of the list. This is the second instance of §4.2's "read the original value before changing a setting": mix the two records up and the user later finds their default keyboard inexplicably swapped.

```bash
while IFS= read -r i; do "$ADB" -s <id> shell ime enable "$i" >/dev/null 2>&1; done < /tmp/imes_enabled.txt
"$ADB" -s <id> shell settings put secure default_input_method "$(cat /tmp/ime_default.txt)"
"$ADB" -s <id> shell settings get secure default_input_method   # re-check: matches /tmp/ime_default.txt
```

**After typing you must read the text back** — typing belongs to the keystone's "silent failure" list just as `io swipe` does: exit code 0 from `input text` only says the event was dispatched, not that the characters landed in the target field. Read the same element's `text` back and compare it **character for character** against what you expected; a mismatch means it was swallowed:

```bash
# Tap into the field → type → read the same element back immediately
mobilecli io tap  --device <id> <center of the field's rect>
mobilecli io text --device <id> "<expected text>"
mobilecli dump ui --device <id> > /tmp/ui.json          # read back: fetch that field's text by identifier/label
# Compare character for character with the expected text; a mismatch = swallowed (don't take exit code 0 for success)
```

The real cause is one of three: **focus never landed in the field** (you tapped the container wrapping it — keystone's smallest-rect rule), **the IME panel intercepted it** (this section; disabling fixes it), or **it isn't a system text field at all** (a Flutter-painted keypad / custom gesture widget, see §8 — disabling IMEs won't help there, you tap key by key).

> **The boundary with §8**: "disable them all" applies to the adb `input text` path that ASCII typing uses. To enter **Chinese/emoji** you need the on-device agent IME that mobilecli installs (§8) — that one must stay enabled and set as the default, with everything else still disabled; it's built for automation and shows no visible panel. The original values to restore are still the two records this section takes.

---

## 5. Teardown: force-stop ≠ kill flutter run (must re-check)

`kill flutter run` only severs the host process; the App on the device keeps running (keystone hard principle). To really close the App:

```bash
"$ADB" -s <id> shell am force-stop <applicationId>   # = mobilecli apps terminate --device <id> <applicationId>
"$ADB" -s <id> shell pidof <applicationId>           # re-check: empty output = really closed
```

- `am force-stop` and `mobilecli apps terminate` are equivalent; mobilecli has smoothed over platform differences, pick either.
- **Re-check iron rule**: after running `force-stop` you must confirm `pidof` is empty; don't treat "I ran force-stop" as "the App is closed" (keystone "don't verify, don't report done").
- Also `force-stop` any leftover Apps from other projects on the same device + re-check the foreground, confirming that after teardown the foreground isn't a leftover App.

---

## 6. Physical Pixels (only for pure canvas with no Semantics)

**This section isn't needed when Semantics is present** — `dump ui` directly gives device-pixel rects; take the center and tap, no conversion. Only when both paths fail for pure-canvas drawing (inside charts, elements not wrapped in Semantics) do you fall back to "eyeball-measure coordinates on a screenshot × scale ratio".

```bash
"$ADB" -s <id> shell wm size      # e.g. Physical size: <W>x<H> — the device's real pixels, not dp
```

Generic scale formula (**don't write specific numbers**, compute at runtime):

```
scale ratio = physical width (W from wm size) / screenshot width (the actual pixel width of the image you Read)
tap coordinate (device pixels) = the coordinate you measured on the screenshot × scale ratio
```

- Why convert: the image from `exec-out screencap` is sometimes already physical pixels (scale ratio = 1), but after a tool re-scales it / a different-DPI screenshot tool, the width changes; **you must compute with the actual width of the image you have in hand**, don't assume 1:1.
- For a horizontally-measured x use "physical width / screenshot width", for a vertically-measured y use "physical height / screenshot height"; they're identical when scaled equally; to be safe compute each separately.
- This is the last resort of last resorts: if you can add `Semantics(label:)` to make the widget dump-able, go back to the code and add it (keystone "can't be listed = code defect, fix it"); don't rely on measuring coordinates long term.

---

## 7. Blind-Tap Last-Resort Commands (with Semantics, always go mobilecli element-driven)

The following are the **platform last resort**, used only for pure canvas where you truly can't get a Semantics rect. The priority is always `mobilecli dump ui` → `io tap` (semantic coordinates) > these blind-tap adb commands.

```bash
"$ADB" -s <id> shell input tap <x> <y>                  # blind-tap (coords must go through §6 conversion)
"$ADB" -s <id> shell input swipe <x1> <y1> <x2> <y2> [<ms>]  # swipe/scroll/pull-to-refresh
"$ADB" -s <id> shell input text "<ASCII text>"          # ASCII only; Chinese/emoji can't be fed in (see §8)
"$ADB" -s <id> shell input keyevent 4                   # 4 = BACK
"$ADB" -s <id> exec-out screencap -p > shot.png         # screenshot (exec-out uses a binary pipe, doesn't corrupt the PNG)
```

- Always use `exec-out` for screenshots (not `shell`); `shell screencap` on some devices converts `\n` to `\r\n` and corrupts the PNG.
- `keyevent 4` is Android-specific BACK; mobilecli's `io button BACK` wraps it, so cross-platform scripts should use the mobilecli one (iOS has no BACK).
- `input text` is ASCII only; escape spaces or use `%s`; non-ASCII goes through §8.
- After a screenshot you must `Read` that image and eyeball-verify it; don't treat "took a screenshot" as "looked at it".

---

## 8. mobilecli's Input Boundary on Android (only non-ASCII needs an agent)

- mobilecli's `io tap` / `io swipe` / `dump ui` / `screenshot` all go through the adb path on Android, **zero extra install**.
- When `io text` inputs **non-ASCII (Chinese/emoji)**, adb `input text` can't feed it → mobilecli needs an on-device input agent (IME) installed on the device to type it. This is a reversible "provisioning tools" operation: install the agent per the mobilecli docs and continue, don't stop and ask for manual help.
- Pure English/numeric input is handled by bare adb `input text`, no agent needed. But **disable the device's input methods per §4.4 before typing** (the panel covers elements and pollutes `dump ui`), and **read the text back afterwards** (exit code 0 ≠ the characters landed).
- Note the distinction: a Flutter **self-drawn numeric keypad / custom gesture control** isn't a system input field at all — neither `io text` nor adb `input text` can feed it → you can only `io tap` each key's rect center one by one (already stated in the keystone).

---

## 9. Toolchain Versions (project-specific, not in this doc)

JDK / Gradle / Android SDK versions are **project-specific**, varying by machine/project → put them in the project `CLAUDE.md`; this doc doesn't hardcode them.

- Just one troubleshooting anchor: when `flutter run` / a Gradle build reports `compileDebugJavaWithJavac` failure, **the most common cause is a JDK version mismatch with the project's requirement** (Gradle used the system default JDK instead of the version the project requires). Read which JDK to use and how to specify it (`org.gradle.java.home` / `JAVA_HOME`) from the project `CLAUDE.md`.
- A toolchain error is a build-environment issue; fix it to the version specified in the project `CLAUDE.md` and re-run; this is still **green zone** and you handle it yourself.

---

## 10. Network-Cut / Offline Testing (network is system state: restore + re-check when done)

To verify offline degradation / error states / reconnect logic, cut the device's network with `svc` — **USB adb is unaffected**, so element-driven interaction / screenshots / logs all keep working while offline:

```bash
"$ADB" -s <id> shell "svc wifi disable; svc data disable"          # cut network
"$ADB" -s <id> shell "dumpsys connectivity | grep 'Active default'" # re-check: none = cut
```

**Recovery pitfall: `svc wifi enable` may fail to bring Wi-Fi back up** (hit on a real Samsung device): `settings get global wifi_on` already reads 1 while `cmd wifi status` still reports "Wifi is disabled", and looping `svc` / `cmd wifi set-wifi-enabled` gets you nowhere. **The reliable recovery path is the Settings UI** — Settings is a native page whose controls have accessibility labels by nature, so element-driven gets it in one step:

```bash
"$ADB" -s <id> shell am start -a android.settings.WIFI_SETTINGS   # open the WLAN settings page
mobilecli dump ui --device <id>                                    # find the Wi-Fi toggle (label like "Toggle"/"Off")
mobilecli io tap --device <id> <toggle-rect-center>                # flip it; should associate to a saved AP within ~10s
```

- **The teardown iron rule, network edition**: if you cut the network, "network restored" becomes part of teardown re-check — prove it with an independent command (`ping -c 1 8.8.8.8` succeeds, or `dumpsys connectivity` shows an Active default network); don't treat "I ran enable" as "network is back". **Leaving the user's device offline is a teardown incident**, no less serious than leaving the app running.
- **The network inside `adb shell` ≠ the app's network**: `adb shell curl/ping` goes through the device's **raw network stack**, **bypassing the TUN set up by any VPN/proxy app on the phone**. So using it to decide "can the app reach this domain" can give you the exact opposite of what the app sees — with a proxy running, `adb shell` can't connect while the app is perfectly fine (and vice versa). **Judge reachability from the app's own evidence**: request outcomes in the logs, state read via the VM Service; use `adb shell` only to verify the **physical link** (is there an Active default network). Get this backwards once and you'll go fix a network bug that doesn't exist, or report a healthy network as "restricted".
- On a SIM-less test device Wi-Fi is the only path (check `getprop gsm.sim.state`) — there is no mobile-data fallback if recovery fails, so re-check until ping succeeds.
- Test-design tip: data already loaded in memory **does not disappear** when you cut the network; to trigger an "empty data + load failure" state you usually need to switch to a not-yet-loaded resource (new symbol / new page) and observe. A cold start while offline may be blocked by an upstream error wall before you ever reach the target page — switching resources is more controllable than cold-starting.

# Tool selection: mobilecli / mobile-mcp / mobilewright / Patrol / adb·simctl — when to use which

> This doc only covers **selection boundaries** — why these tools exist, what each can and can't do, and which to pick for which scenario.
> The methodology (element-driven over blind-tap, the Key+Semantics dual-tag, the four verification layers, teardown re-check) lives in `SKILL.md` and is not repeated here.

---

## Memorize this one-liner first

- **Self-driving runs, instant interaction/exploration/diagnosis** → `mobilecli` (already-installed binary, no MCP/restart needed — this is the default hand).
- **Want the MCP tool flow (already registered)** → `mobile-mcp` (same engine, different skin; screenshots save tokens, but config changes only take effect next session).
- **Want repeatable Flutter assertions, into CI** → `Patrol` (Dart VM by Key, stable on both iOS/Android — Flutter's only reliable deterministic path).
- **Want repeatable TS scripts / system-level / cross-app / embedded webview** → `mobilewright` (Playwright-style, but **Flutter ⏳ not officially supported**).
- **Pure canvas blind-tap (no Semantics at all)** → `adb` (Android) / `simctl`·WDA (iOS), **last resort**.

---

## ★ Same origin, same base: all three run on top of mobilecli

mobilecli, mobile-mcp, and mobilewright all come from **mobile-next** and share one device engine:

```
                  ┌─ mobile-mcp     (MCP protocol wrapper, ~23 mobile_ tools)
mobilecli  ───────┼─ mobilewright   (Playwright-style TS framework, driver-mobilecli over WS JSON-RPC)
(device engine/CLI/HTTP·WS server)        the rest use mobilecli CLI or HTTP/WS API directly
```

Implications:
- The three have an **identical capability ceiling** — the underlying layer is the same engine talking to iOS (WebDriverAgent / simctl / on-device agent) and Android (adb / UI Automator). The upper layers only differ in **delivery form**: CLI / MCP tools / TS locator.
- Selection is essentially choosing a **delivery form**, not choosing "who can do it": if a one-line mobilecli command does it, don't spin up MCP or write TS for it.
- mobilecli can run as a server (`mobilecli server start`, default port 12000, HTTP `/rpc` + WS `/ws`, JSON-RPC 2.0). **Running it in server form is recommended**: it caches and keeps the tunnel alive, significantly speeding up repeated interaction with the device/simulator. mobilewright's driver-mobilecli connects to exactly this WS.

---

## mobilecli — the default hand for self-driving instant interaction / exploration / diagnosis

**Why default**: once installed it's just a binary, **does not depend on MCP registration, needs no session restart** — usable immediately after install; the coordinate-level `dump ui` → `io tap` loop is the shortest, ideal for "tap it yourself, look yourself, keep moving smoothly".

### Command-surface quick reference

| Domain | Command | Purpose |
|---|---|---|
| **devices** | `mobilecli devices` / `--include-offline` | List online devices (JSON); add `--include-offline` to include unbooted simulators/emulators |
| **device** | `device boot` / `device shutdown` | Boot / shut down simulator·emulator |
| | `device reboot` | Reboot device |
| | `device info` | Device info |
| | `device orientation` | Read/set orientation |
| | `device crashes list` / `crashes get <id>` | List crash reports / get a stack trace (iOS real device via crashreport service; simulator reads DiagnosticReports; Android parses `logcat -b crash`) |
| | `device url <deeplink>` | Open deeplink / custom scheme — **deep-link jumps to a screen**, saving step-by-step navigation |
| **apps** | `apps launch <bundleId>` | Bring App to foreground |
| | `apps terminate <bundleId>` | Truly close App (Android=force-stop / iOS=simctl terminate, already smoothed over) |
| | `apps foreground` | **Current foreground App** (cross-talk check: is `packageName` == target package) |
| | `apps list` | List installed Apps |
| | `apps install <path>` / `apps uninstall <bundleId>` | Install (.apk/.ipa/.zip) / uninstall |
| | `apps path <bundleId>` | App data container path (Android) |
| **io** | `io tap x,y` | Tap coordinate (take the center of the `dump ui` rect, don't blind-guess) |
| | `io longpress x,y [--duration ms]` | Long press |
| | `io swipe x1,y1,x2,y2` | Swipe / list scroll / pull-to-refresh / drag slider |
| | `io text 'text'` | Type into a system input field (Flutter's self-drawn keyboard won't accept it; tap key-by-key with `io tap`) |
| | `io keys` | Send a key sequence |
| | `io button <HOME\|BACK\|POWER\|VOLUME_UP\|...>` | Hardware key (**BACK / DPAD Android only**; iOS has no BACK — use gestures/nav-bar tap) |
| | `io gesture` | Custom gesture |
| **dump ui** | `dump ui` | List elements: label + **device-pixel rect{x,y,width,height}**; dump and inspect before interacting |
| **screenshot** | `screenshot [-o file\|-]` / `--format jpeg --quality N` | Screenshot → Read to verify; `-o -` outputs to stdout |
| **fs** | `fs ls / pull / push / mkdir [-p] / rm [-r]` | Device/container file read/write (**Android + iOS simulator**; `/data/user/` requires app to be debuggable) |
| **webview** | `webview list / goto / reload / back / forward / url / title / content / query <css> / eval <js> / wait` | Inspect and operate embedded webviews (**query/eval act only on webview DOM, not on native/Flutter widgets**) |
| **agent** | `agent status / install [--force] [--provisioning-profile]` | On-device agent (**required for iOS touch/stream/UI tree**; on Android only needed for non-ASCII input) |
| **server** | `server start [--listen :12000]` | Start HTTP `/rpc` + WS `/ws`, cache & keep-alive, speed up repeated interaction |
| **remote** | `remote allocate / list-devices / release` | Cloud devices (device lab) |

> Almost every command takes `--device <id>`; the device id is **fetched live at runtime from `mobilecli devices`, never written into a file**.

---

## mobile-mcp — same engine, MCP-ified (optional; config changes take effect next session)

**What it is**: wraps the same engine as an MCP server, exposing ~23 `mobile_` tools (`mobile_list_elements_on_screen` / `mobile_click_on_screen_at_coordinates` / `mobile_launch_app` / `mobile_take_screenshot` / `mobile_swipe_on_screen` / `mobile_type_keys` / `mobile_press_button` / `mobile_open_url` / `mobile_list_crashes` / ...). Capability equivalent to mobilecli.

**When to use it instead of mobilecli**:
- You want interaction to go through the MCP tool flow (recorded/reused as tool calls, orchestrated alongside other MCPs).
- Screenshots to save tokens: `mobile_take_screenshot` has **built-in compression**, leaner than mobilecli's raw image.

**Registration** (Claude Code):
```bash
claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest
```
> ⚠️ **Changing MCP config = it only connects next session**. Don't fall back to blind-tap adb this session just because "it's not registered yet" — use mobilecli to cover now, leave registration for next time.

**Pitfalls and boundaries (where it must be backed up relative to mobilecli)**:
- **No foreground-check tool**: no equivalent of `apps foreground` → for cross-talk prevention fall back to `mobilecli apps foreground` or Android `dumpsys`.
- **No fs tool**: container read/write falls back to mobilecli `fs` or adb.
- `mobile_open_url` opening a **custom scheme** needs unlocking: `MOBILEMCP_ALLOW_UNSAFE_URLS=1`.
- **Telemetry on by default** (PostHog) → register with `MOBILEMCP_DISABLE_TELEMETRY=1`:
  ```bash
  claude mcp add mobile-mcp -e MOBILEMCP_DISABLE_TELEMETRY=1 -e MOBILEMCP_ALLOW_UNSAFE_URLS=1 -- npx -y @mobilenext/mobile-mcp@latest
  ```

---

## mobilewright — Playwright-style TS framework (Flutter ⏳ not officially supported)

**What it is**: the Playwright dev experience ported to mobile, also running on top of mobilecli (`driver-mobilecli` over WS JSON-RPC). Selling points:
- **Semantic locator + auto-wait**: `screen.getByLabel('Email').fill(...)` / `getByRole('button', {name:'Sign In'}).tap()` / `getByTestId(...)`, each action auto-waits for the element to be visible·enabled·bounds-stable, **no hand-written sleep / coordinates needed**.
- **Assertion retry**: `expect(locator).toBeVisible()` polls until satisfied or timeout.
- **reporter** (list/html/json/junit) + **projects multi-device/multi-platform matrix** + **retries** + **CI-friendly** (`@mobilewright/test` extends Playwright Test, fixtures `device`/`screen`, auto-screenshots on failure, optional recording).
- `npx mobilewright doctor [--json]` is a **ready-made cross-platform health check** (Node / Xcode / Simulators / ADB / Java / mobilecli agent) — use it as the entry point for environment bootstrapping.

**★ But the key limitation for this skill — Flutter ⏳ not officially supported**:
- In the framework support table, **Flutter is marked ⏳ on both iOS / Android** (note: Renders via Skia/Impeller, not native views — requires Dart VM Service driver). Flutter paints to canvas and emits no native views, so mobilewright's semantic locator can't get stable native nodes.
- Even if a widget exposes Semantics, **Flutter widgets — especially `getByRole` on iOS — are unreliable** (role mapping targets UIKit/SwiftUI/RN native types, which Flutter doesn't match).
- Conclusion: **do not bet UI assertions inside a Flutter project on mobilewright** — that's Patrol's job.

**So what is mobilewright for within this skill**:
- Writing **repeatable TS scripts** (team is used to Playwright, wants reporter/CI matrix, and the target is **native/RN/webview** rather than Flutter canvas).
- **System-level / cross-app flows** (leaving the Flutter App for Settings, Photos, or a stretch through another native App).
- **Embedded webview content** (webviews go through the native accessibility tree, so the locator works).
- **`mobilewright doctor`** as the environment health-check entry point (this one is unrelated to Flutter, usable anytime).

---

## Patrol — Flutter's only reliable deterministic assertion path

**What it is**: Dart VM directly connected to the widget tree, precise lookup by `Key` + `expect` assertions, **stable on both iOS / Android, produces pass/fail, repeatable into CI**. It does not depend on whether the system accessibility tree exposes anything — which is exactly why it's more reliable for Flutter than mobilewright/mobile-mcp (it looks at the tree on the Dart side, not the canvas on the native side).

**When it must be it**:
- Any Flutter UI/integration assertion that needs **regression, repeatability, pass/fail, or CI**.
- When an element-driven one-off tap has gone through, but you need to freeze it into a long-lived regression case.

**Division of labor with element-driven** (both within this skill, complementary):
- Exploration phase / one-off verification → mobilecli `dump ui`→`io tap` (fast, leaves no assets).
- Solidification phase / regression → Patrol by Key (a bit slower, leaves a repeatable case).
- Hence the two share one code contract: interactive/assertable widgets get **both** a `Key` (for Patrol) and `Semantics(label:)` (for element-driven).

> Commands and code templates are in `SKILL.md` "Full self-driving development loop" section, not duplicated here.

---

## ★ Key fact: there is no native "tap by label in one step" command

An easy misconception: assuming mobilecli/mobile-mcp can do `getByLabel('X').tap()` in one step like mobilewright. **They can't**:

- **mobilecli / mobile-mcp are both coordinate-level**: the capability is "list elements (with label + pixel rect)" + "tap coordinate" — two steps, **no native command to tap by label directly**.
- mobilecli's `webview query` / the `getBy*` that mobile-mcp lacks — those **act only on the webview DOM** (CSS selector / JS), **not on native widgets, and certainly not on Flutter's Semantics tree**.
- The real "one-step locator" is **mobilewright**, but it **⏳ doesn't support Flutter** (see above).

**So "tap by label in one step" on Flutter relies on**: `scripts/tap-by-label.sh <deviceId> "<label-substring>"` (zero-dependency jq): internally `dump ui` → jq picks the rect by label → computes center → `io tap`. This glues the two steps "list elements + tap coordinate" into one inside a script, filling in the command mobilecli lacks.

---

## Decision rule table (pick against this)

| What you want to do | Pick this | Because |
|---|---|---|
| **Instant interaction / exploration / diagnosis** in a self-driving run (tap-and-see, navigate, grab crashes, check foreground) | **mobilecli** | already-installed binary, no MCP/restart, shortest loop |
| Want to go through the **MCP tool flow** (already registered / want screenshots to save tokens / orchestrate with other MCPs) | **mobile-mcp** | same engine, different skin; but config takes effect next session, no foreground check / no fs |
| **Repeatable Flutter UI/integration assertions** (regression, CI, want pass/fail) | **Patrol** | Dart VM by Key, Flutter's only reliable deterministic path |
| **Repeatable TS scripts / system-level / cross-app / embedded webview** (and target is not Flutter canvas) | **mobilewright** | Playwright-style locator + auto-wait + reporter + CI; **Flutter ⏳ not supported** |
| **Environment health check** | **mobilewright doctor** | ready-made cross-platform, `--json` is machine-readable |
| **Tap a Flutter widget by label in one step** | **`scripts/tap-by-label.sh`** | mobilecli/mobile-mcp have no such native command; mobilewright doesn't support Flutter |
| **Pure canvas blind-tap** (inside charts etc. with no Semantics at all) | **adb** (Android) / **simctl·WDA** (iOS) | last resort; as long as there's Semantics, always go element-driven |

> Ordering mantra: **if mobilecli can do it don't spin up MCP, if element-driven works don't blind-tap, if you need regression bring in Patrol, never bet Flutter assertions on mobilewright.**

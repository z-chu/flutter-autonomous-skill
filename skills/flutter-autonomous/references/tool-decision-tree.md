# Tool selection: mobilecli / mobile-mcp / mobilewright / Patrol / adb·simctl — when to use which

> This doc only covers **selection boundaries** — why these tools exist, what each can and can't do, and which to pick for which scenario.
> The methodology (element-driven over blind-tap, the Key+Semantics dual-tag, verification layering, teardown re-check) lives in `SKILL.md` and is not repeated here.

---

## Memorize this one-liner first

- **Self-driving runs, instant interaction** (tap, type, swipe) → `mobilecli` (already-installed binary, no MCP/restart needed — this is the default hand; **it is the only one that can tap**).
- **Diagnosis/evidence** (does the widget exist, which line painted it, are the layout sizes right, did this step error) → **VM Service** (the channel `flutter run` already opened, one curl, **no accessibility-tree dependency** → `vm-service.md`).
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

### Command surface: only the parts the environment can't tell you

**For the full command surface run `mobilecli --help` / `mobilecli <domain> --help`** — that's the one source that never goes stale. Listed here are only the traps and usages `--help` won't reveal:

| Command | What `--help` won't tell you |
|---|---|
| `devices` | Output is JSON `{status,data:{devices:[…]}}`, take `.data.devices[0].id`; only `--include-offline` includes unbooted simulators |
| `device crashes list` / `crashes get <id>` | The entry point for failure classification: read the first `package:<your_app>/` line of the stack. Three different backends (iOS device crashreport service / simulator DiagnosticReports / Android `logcat -b crash`), already smoothed over |
| `device url <deeplink>` | **Deep-link jump** — lands directly on a screen, skipping step-by-step navigation; the most underrated command here |
| `apps terminate` | Android=force-stop / iOS=simctl terminate, already smoothed over. **`kill flutter run` is not this** |
| `apps foreground` | **Cross-talk check**: the returned `packageName` must equal the target package — check before screenshotting/tapping |
| `apps path <bundleId>` | **Android only**; on iOS this is the only way to a container path, there is no arbitrary-path `fs` |
| `io tap x,y` | Take the center of the `dump ui` rect — **never blind-guess, never hardcode historical coordinates** |
| `io text 'text'` | System input fields only. **Flutter's self-drawn keyboard / custom gesture widgets won't accept it** → tap key-by-key; non-ASCII on Android needs the on-device agent first |
| `io button <KEY>` | **BACK / DPAD are Android only**; iOS has no BACK — use a gesture or tap the nav-bar back control |
| `dump ui` | Returns **device physical pixel** rects, usable as-is with no conversion; on iOS stderr carries heavy tunnel logging — **never write `2>&1`**, it corrupts the JSON |
| `fs ls/pull/push/rm` | **Android + iOS simulator only**; `/data/user/` requires the app to be debuggable |
| `webview query <css>` / `eval <js>` | **Acts only on webview DOM** — not on native widgets, and certainly not on Flutter's Semantics tree (the most common misconception; see the end of this doc) |
| `agent install [--provisioning-profile]` | **Required for iOS touch/stream/UI tree**; on Android only for non-ASCII input. For a real device just pass the app's own `embedded.mobileprovision` |
| `server start [--listen :12000]` | Starts HTTP `/rpc` + WS `/ws` — **caches and keeps tunnels alive, markedly faster for repeated interaction**; worth starting when you'll hit the same device many times |

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
| **Diagnosis & evidence**: does the widget exist / is the Key spelled right / which line painted it / real layout size / did this step error | **VM Service** | the channel `flutter run` already opened, one curl; **no Semantics dependency**, the widget tree carries `Key` and source line numbers → `vm-service.md` |
| Want to go through the **MCP tool flow** (already registered / want screenshots to save tokens / orchestrate with other MCPs) | **mobile-mcp** | same engine, different skin; but config takes effect next session, no foreground check / no fs |
| **Repeatable Flutter UI/integration assertions** (regression, CI, want pass/fail) | **Patrol** | Dart VM by Key, Flutter's only reliable deterministic path |
| **Repeatable TS scripts / system-level / cross-app / embedded webview** (and target is not Flutter canvas) | **mobilewright** | Playwright-style locator + auto-wait + reporter + CI; **Flutter ⏳ not supported** |
| **Environment health check** | **mobilewright doctor** | ready-made cross-platform, `--json` is machine-readable |
| **Tap a Flutter widget by label in one step** | **`scripts/tap-by-label.sh`** | mobilecli/mobile-mcp have no such native command; mobilewright doesn't support Flutter |
| **Pure canvas blind-tap** (inside charts etc. with no Semantics at all) | **adb** (Android) / **simctl·WDA** (iOS) | last resort; as long as there's Semantics, always go element-driven |

> Ordering mantra: **if mobilecli can do it don't spin up MCP, if element-driven works don't blind-tap, if you need regression bring in Patrol, never bet Flutter assertions on mobilewright.**
>
> And one more, equally important: **to tap use mobilecli, for evidence use VM Service, for regression use Patrol** — the three are a division of labor, not substitutes. When a widget can't be found, the layout is wrong, or you suspect an error, check the VM Service first instead of eyeballing screenshots; and **whatever can be proven offline — interaction and visuals alike — shouldn't reach a device at all** (see the widget test / golden layers in `offline-test-layer.md`).

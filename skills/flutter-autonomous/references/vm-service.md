# Dart VM Service: evidence and control from inside the app (the third path)

> This doc expands the **third** of the "three paths to finding widgets" in the keystone (`../SKILL.md`). The methodology (element-driven first, the Key+Semantics double tag, verification layering, re-checking at teardown) is owned by the keystone; this doc only covers **what this channel can do, how to call it, and where its boundaries are**.
>
> One-line positioning: element-driven interaction and screenshots both look at the app from the **outside** (accessibility tree, pixels); Patrol looks from the inside but **requires writing a test file and rebuilding**. VM Service is the third option — **the app is already running, and without writing a single test or rebuilding anything, you pull the widget tree, layout sizes, runtime state and errors straight out of it**. The channel has been open since the moment `flutter run` started; it just went unused.

---

## 1. Division of labor between the three paths (don't mix them up)

| Path | What it sees | Cost | When to use |
|---|---|---|---|
| **Element-driven** (`dump ui`) | system accessibility tree: label + device-pixel rect | zero (mobilecli already installed) | **when you need to tap/interact** — only it gives tappable coordinates |
| **Patrol** | the Dart widget tree, assertions by `Key` | a test file + one build cycle | **when you need repeatable regression, into CI** |
| **VM Service** (this doc) | Dart widget/render tree, runtime state, structured errors | zero (`flutter run` already opened it) | **when you need diagnosis/evidence/assertions but no tapping** |

The key complementarity: **VM Service does not depend on the accessibility tree**. The keystone says "for pure canvas painting, both other paths fail → fall back to screenshots and measured coordinates" — that is a last resort *for tapping*; at the level of *judging*, this path still sees everything: a widget with no `Semantics` that `dump ui` can't list still appears in the widget tree, with a source line number.

> ⚠️ The reverse is also true: **this path cannot give you tappable coordinates** (the widget tree has no device-pixel rects). To tap, go back to `dump ui`. Don't expect it to replace element-driven interaction.

---

## 2. Opening the channel: two entry points, prefer `--vmservice-out-file`

### 2.1 Getting the URI (instead of grepping stdout)

The keystone's "wait for the build" polls for the `--vmservice-out-file` to land. **Letting flutter write the URI to a file itself is the reliable way** — the file appearing means the VM Service is ready, with no human-readable output to parse:

```bash
flutter run -d <deviceId> --target <entry> \
  --pid-file=<PID_FILE> --vmservice-out-file=<URI_FILE> <dart-defines> > <LOG_FILE> 2>&1
# poll from a separate background Bash (a non-empty file = the VM Service is up).
# Always include the "process died" and "timeout" exits as well — see the keystone's §Backgrounding flutter run.
```

What gets written is the ws form: `ws://127.0.0.1:<port>/<token>/ws`.

### 2.2 Convert to HTTP, then use curl for everything

**The VM Service accepts HTTP GET on the same port**, so one sed gets you a base URL and every introspection call afterwards is a one-line curl with zero dependencies:

```bash
VM=$(sed 's|^ws://|http://|; s|/ws$|/|' "<URI_FILE>")     # → http://127.0.0.1:<port>/<token>/
ISO=$(curl -s "${VM}getVM" | jq -r '.result.isolates[0].id')
```

### 2.3 ★ The HTTP vs WebSocket capability boundary (measured — don't trip on this)

| Over HTTP GET (curl, zero deps) | Requires WebSocket |
|---|---|
| all `ext.flutter.*` service extensions | **`evaluate`** (read/modify runtime state, call functions) |
| `getVM` / `getIsolate` / `getMemoryUsage` | **event streams** (`streamListen` + `Flutter.Error` structured errors) |

- Calling `evaluate` over HTTP returns `code 113 / "No compilation service available; cannot evaluate from source"` — **this is not a malformed command**; a one-shot HTTP request simply can't reach the expression compilation service. Connect to the same app over WS and `evaluate` works immediately. Unrelated to `--machine`.
- HTTP is a **one-shot request**, so it inherently cannot subscribe to event streams.
- Conclusion: **use curl for introspection; only start a WS client when you need evaluate or want to subscribe to error events** (the `--machine` daemon protocol, or `package:vm_service`, or any WS client).

### 2.4 Alternative entry point: `flutter run --machine` (the daemon protocol)

`--machine` makes flutter speak JSON-RPC over stdin/stdout. It gives you two things curl cannot:

```jsonc
// call a service extension (equivalent to the curl above, but via the daemon)
{"id":1,"method":"app.callServiceExtension",
 "params":{"appId":"<appId>","methodName":"ext.flutter.debugDumpApp","params":{}}}

// ★ hot reload, with a【structured success/failure result】
{"id":2,"method":"app.restart","params":{"appId":"<appId>","fullRestart":false,"reason":"edit"}}
// → {"id":2,"result":{"code":0,"message":"Reloaded 0 libraries"}}
```

- The `app.started` event gives you `appId`; the `app.debugPort` event gives you `wsUri` (no need to read the file).
- **`app.restart` is the upgraded `kill -USR1`**: a signal is fire-and-forget, whereas the daemon protocol **returns code/message**, so `code!=0` *is* the "hot reload failed" assertion — no grepping output and guessing. Use it when a code change must be confirmed; for casual reloads the keystone's signal is less hassle.

---

## 3. Six measured recipes (copy-paste ready)

All commands below have been verified on real devices. `$VM` and `$ISO` come from §2.2.

### 3.1 ★ Widget tree + source line numbers (the most valuable one)

One curl gets you "what widgets are on screen, which line of code painted each one, and what its Key is":

```bash
curl -s "${VM}ext.flutter.inspector.getRootWidgetSummaryTree?isolateId=${ISO}&objectGroup=ai" \
 | jq -r '[.result.result] | .. | objects | select(.description? and .createdByLocalProject?)
          | "\(.description)  ←  \(.creationLocation.file | split("/") | last):\(.creationLocation.line)"'
```

Measured output shape:

```
Scaffold-[<'home_screen'>]        ←  main.dart:55
Text-[<'counter_text'>]           ←  main.dart:62
ElevatedButton-[<'inc_btn'>]      ←  main.dart:65
GestureDetector-[<'unlabeled_gesture'>]  ←  main.dart:72
```

Key points:
- The parameter is **`objectGroup`** (not `groupName`; getting it wrong returns a 500 with `Null check operator used on a null value`).
- `createdByLocalProject: true` filters out framework nodes, leaving only your code.
- **The `Key` is shown directly in the description** (`-[<'home_screen'>]`) — use it to check Key spelling before writing a Patrol test, faster than grepping code, and it cures the keystone's `found 0 widgets`.
- This is a **direct mapping from the current page to source lines**: whatever looks wrong in the screenshot, you find the line that painted it in one step, no grep.

### 3.2 Measured layout sizes and constraints (no eyeballing screenshots)

```bash
curl -s "${VM}ext.flutter.debugDumpRenderTree?isolateId=${ISO}" | jq -r '.result.data' \
 | grep -E "constraints:|size:"
# → constraints: BoxConstraints(w=411.4, h=820.6)
#   size: Size(411.4, 820.6)
```

Misaligned layouts, elements not filling their space, overflows — **numbers beat eyes**. The keystone's "use screenshots for visuals/layout" still holds, but **read these numbers first and use the screenshot to confirm the look**.

### 3.3 The whole widget tree (text form)

```bash
curl -s "${VM}ext.flutter.debugDumpApp?isolateId=${ISO}" | jq -r '.result.data'
```

More complete than §3.1 but very long (all framework nodes included). **Default to the structured version in §3.1**; use this only when you need the full nesting relationship, and always truncate.

### 3.4 Screenshot of a single widget (saves tokens)

```bash
# id comes from the valueId in the §3.1 result (e.g. "inspector-0")
curl -s "${VM}ext.flutter.inspector.screenshot?isolateId=${ISO}&id=<valueId>&width=400&height=800&maxPixelRatio=1.0&debugPaint=true" \
 | jq -r '.result.result' | base64 -d > widget.png     # measured at roughly 10KB
```

This captures **one widget subtree** instead of the whole screen, and `debugPaint=true` also draws layout boundaries. Far cheaper than full-screen screenshots when verifying the same component repeatedly.

### 3.5 Runtime switches (no system settings, no restart)

```bash
curl -s "${VM}ext.flutter.brightnessOverride?isolateId=${ISO}&value=Brightness.dark"   # switch to dark mode
curl -s "${VM}ext.flutter.platformOverride?isolateId=${ISO}&value=iOS"                 # see the iOS look on Android
curl -s "${VM}ext.flutter.timeDilation?isolateId=${ISO}&timeDilation=1.0"              # animation time scaling
curl -s "${VM}ext.flutter.debugPaint?isolateId=${ISO}&enabled=true"                    # draw layout boundaries
curl -s "${VM}getMemoryUsage?isolateId=${ISO}" | jq -c '.result'                       # heap usage (leak baseline)
```

`brightnessOverride` is the correct way to verify dark mode: **no system setting changes, no app restart, no polluted device state** — flip it, screenshot, compare, and there's nothing to restore at teardown (it dies with the process).

### 3.6 evaluate: read runtime state / trigger actions (needs WS)

Assertions go from "does the number in the screenshot look right" to "read the variable directly":

```jsonc
{"jsonrpc":"2.0","id":1,"method":"evaluate",
 "params":{"isolateId":"<iso>","targetId":"<rootLib.id>","expression":"<expression>"}}
// → result.valueAsString is the value itself
```

`targetId` comes from `.result.rootLib.id` of `getIsolate`, and the expression is evaluated **in the root library's scope**. Measured to work for: reading top-level variables, calling top-level functions, writing top-level variables.

**The matching code contract**: the root library scope cannot see private fields inside a `State`. To make this path usable, leave a **debug-only hook** for key state — a top-level variable or a registry maintained only under `kDebugMode`:

```dart
// state hook: readable directly by evaluate; you can also expose top-level functions for evaluate to trigger actions
int e2eCounter = 0;
final ValueNotifier<bool> e2eFlag = ValueNotifier(false);
String e2eTrigger() { e2eFlag.value = true; return 'ok'; }
```

Uses: ① assert on state instead of pixels ② **put the app into a given state in one step**, skipping N navigation steps (finer-grained than a deeplink — you can set internal state directly).

---

## 4. Structured errors: one notch harder than grepping logs (needs WS)

Subscribe to the `Extension` stream and every uncaught Flutter error arrives as a `Flutter.Error` event:

```jsonc
{"jsonrpc":"2.0","id":1,"method":"streamListen","params":{"streamId":"Extension"}}
// then streamNotify arrives with event.extensionKind == "Flutter.Error" and event.extensionData shaped like:
{
  "description": "Exception caught by rendering library",
  "properties": [
    {"description": "A RenderFlex overflowed by 300 pixels on the right."},
    {"description": "The overflowing RenderFlex has an orientation of Axis.horizontal."}
  ],
  "errorsSinceReload": 0,
  "renderedErrorText": "..."
}
```

Compared with the keystone's existing `logcat | grep "RenderFlex overflowed"`:

- **It's structured JSON, not a regex** — `properties` come itemized, no digging through human-readable text.
- **`errorsSinceReload` can be used as an assertion directly**: "after this step, the number of new errors must be 0" is a far harder acceptance condition than a screenshot, and it's **generic across all error types** — no need for one grep per error kind.
- Broader coverage than grep: overflows, assertion failures, exceptions thrown in build — all come through here.

The matching switch (HTTP is fine): `curl -s "${VM}ext.flutter.inspector.structuredErrors?isolateId=${ISO}&enabled=true"`.

> **Fallback if you don't want a WS client**: errors also go to the platform log, so the keystone's `logcat -s flutter | grep` still catches them. Only the `errorsSinceReload` assertion requires WS.

---

## 5. Traps and boundaries (learned the hard way)

1. **`ext.flutter.debugDumpSemanticsTreeInTraversalOrder` is not a reliable oracle.** With no accessibility client attached it returns `"Semantics not generated for ..."`; only with a client attached does a tree exist. **Always judge widget existence from the widget tree (§3.1), never from this.**
2. **Calling `SemanticsBinding.instance.ensureSemantics()` inside the app does not make `dump ui` more reliable.** Measured A/B: with and without it, `mobilecli dump ui` returns exactly the same thing — because UI Automator / WDA are themselves accessibility clients, and Flutter generates the semantics tree as soon as one attaches. **Don't change app code for this.**
3. `getRootWidgetSummaryTree`'s parameter is **`objectGroup`**; writing `groupName` returns a 500.
4. `debugDumpApp` / `debugDumpRenderTree` return `{"data": "<very long text>"}` — **grep/truncate before reading**; dumping the whole block into context is extremely wasteful.
5. **The port changes with every `flutter run`** — `$VM` must be taken at runtime from `--vmservice-out-file` and **never written into any file** (the same principle as the keystone's "never hardcode a device id").
6. This channel **exists only in debug/profile builds**; there is none in a release build.

---

## 6. Which path for which job (decision table)

| What you want to do | Which path |
|---|---|
| Tap / type / swipe | element-driven `dump ui` → `io tap` (**only it can tap**) |
| "Does this widget exist / which line painted it" | **VM Service §3.1** (no Semantics dependency, plus line numbers) |
| "Is the Key spelled right / why `found 0 widgets`" | **VM Service §3.1** (the Key is shown directly) |
| "Why is the layout off / are the sizes right" | **VM Service §3.2** for constraints/size, then a screenshot to confirm the look |
| "Did this step produce an error" | **VM Service §4** `errorsSinceReload`; without WS, logcat grep |
| "Where is the state machine / what is this value" | **VM Service §3.6** evaluate; or the keystone's log anchors |
| Dark mode / cross-platform look verification | **VM Service §3.5** `brightnessOverride` / `platformOverride` |
| Repeatable, into CI, pass/fail | **Patrol** (this path produces no repeatable asset) |

> The mantra: **to tap use element-driven, for evidence use VM Service, for regression use Patrol.** The three are not substitutes for each other — they're a division of labor.

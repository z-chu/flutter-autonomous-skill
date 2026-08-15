# The sub-second offline test layer (three layers, no device)

> This doc is a deep dive into **A. the offline layer (①②③)** of the "Verification layering" section in [SKILL.md](../SKILL.md); terminology/principles defer to SKILL and must not contradict it.
> SKILL already covers the "loop order", "four red lines", "self-repair ≤5 rounds", "on assertion failure fix the implementation", etc.; here we only fill in what SKILL doesn't expand on — **how to write them, how to build data, where to put it, and how to run it**.

The three layers each cover one segment, and **a single `flutter test` runs them all**:

| Layer | Covers | Where in this doc |
|---|---|---|
| ① **Pure-logic fixtures** | decode/parse/numerics/state machines/error handling | §3, four strategies |
| ② **widget test** | widget interaction, navigation, forms, conditional rendering | §4 |
| ③ **golden + a11y guideline** | visual regression matrix, accessibility-contract self-check | §5 |

> ⚠️ **Get the priority straight — don't put the cart before the horse**: this skill's main event is **running the app on a device and looking at the UI** (see [SKILL.md](../SKILL.md) §0 — writing plain unit tests should not invoke this skill at all). These three layers exist to **filter out, before you go to the device, everything that doesn't deserve device time**, so device time concentrates on what only a device can verify; **they clear the way for the device layer, they don't replace it**.
>
> - **Worth pushing down here**: pure-logic bugs (parse errors, wrong arithmetic, null derefs) are a waste of real-device time — the offline layer pinpoints the line in seconds; repeatedly-run static visual regression can be locked down with goldens instead of eyeballing the same screen every time.
> - **Must never be pushed down here**: **offline-green ≠ the UI is fine.** Widget tests run headless — no real rendering pipeline, no real font metrics, no platform channels, no real-device timing. They can prove "logically it should display X"; they **cannot prove "it looks right on a real device"**. Whenever the task says "run it and see / how does it look / is it misaligned", **you must go to the device and verify by screenshot** — you don't get to close it out with these three layers.
>
> In one line: **these three layers exist to save device time, not to avoid the device.**

---

## 1. Why this layer beyond on-device (the two layers complement each other)

The on-device layer (element-driven + Patrol + screenshots) is in essence **integration + visual**: slow, needs a device, and **non-deterministic** (networked, external data shifts, timing-sensitive, animated). It can't prove — and shouldn't be used to prove — issues like:

- "When this parser eats dirty/malformed data, is the output correct?"
- "When this service that depends on external IO has its dependency throw / time out, does it crash, or does it leak the internal error up to callers?"
- "Is the precision of this numeric computation good enough at some magnitude?"

These are all **pure logic**, and should have a dedicated layer to lock them down: **offline, deterministic, sub-second, no device, CI-friendly**. The two layers each cover one segment and complement each other:

| Layer | What it locks | Traits |
|---|---|---|
| **Offline layer** (this doc, ①②③) | pure logic + **widget interaction/navigation** + **visual regression/accessibility contract** | Freezes the outside world into deterministic input; sub-second, no device, runnable on every push |
| **Device layer** (main SKILL body, **this skill's main event**) | real rendering, real-device interaction, system integration, real data, device-only capabilities | Needs a device, slow — but **this is the reason this skill exists** |

Two mantras, and **you need both**:

1. **Logic that can be proven offline must not occupy real-device time** — a pure-logic bug is pinpointed in seconds; don't trade tens of minutes of device time for it.
2. **Anything that requires looking at the UI must actually go to the device** — no amount of offline green counts as having looked at the UI. **Mantra 2 outranks mantra 1**: saving time is an optimization; missing a UI problem is not doing the work.

---

## 2. Where it slots into the closed loop

The offline layer sits after `flutter analyze` and before going on-device:

```
flutter analyze (zero warnings)
  → flutter test / dart test   ← 【offline layers ①②③: this doc】sub-second, deterministic, no device
        ├─ ① pure logic fails = logic bug                        ┐
        ├─ ② interaction/navigation fails = behavior bug          ├─ all of these:【don't go on-device, fix directly】
        └─ ③ golden/guideline fails = visual or a11y contract bug ┘
  → confirm device online → VM Service evidence / element-driven (one-shot dump→tap)
  → patrol test (repeatable assertions, into CI)
```

Iron rule: **only go on-device once the offline layer is all green**. Running the device with `flutter test` still failing means spending tens of minutes of device time locating a pure-logic bug that could be pinpointed in seconds.
Commands like `/ship`, `/verify`, `/nightly` all **insert a `flutter test` step first** — after `flutter analyze` and before `patrol test`.

---

## 3. Four strategies (pick by "what the subject under test eats")

Subject eats external JSON/frames → **A**; eats a binary byte stream → **B**; is a service depending on external IO and you want to test control flow / error handling → **C**; you just want to probe the real data distribution, not enter regression → **D**.

---

### Strategy A: real data → JSON fixture (test the dirty data of the real world)

**When to use**: the code consumes an **external data source** (REST/GraphQL responses, WebSocket frames, external RPC, third-party SDK returns), and that data ① shifts ② has all sorts of unexpected dirty / boundary cases ③ is slow and unstable over the network.

**How**: write a **pure-Dart fetch CLI** (does not `import 'package:flutter/...'`, runs directly with `dart run`), freeze real responses into JSON, and replay offline afterward. The CLI offers two subcommands; the skeleton is very generic:

```dart
// tools/fetch_cli.dart —— pure Dart, no flutter dependency, runs directly with `dart run`
// Subcommands:
//   list <query> [--limit=10]       list the id + status of the last N records (pick which ones to freeze first)
//   dump <id>    [--out=path.json]  fetch one full response, extract the [minimal field subset] into JSON
//
// Two reusable key designs:
// 1) When dumping, [extract only the field subset the assertions will use], don't store the whole response verbatim
//    —— a fixture should be small, stable, and readable; storing the full payload freezes the noise in too,
//       and one extra irrelevant field from the upstream makes the fixture diff jitter.
// 2) When the fetch fails, give an [actionable] error, not a stack trace.
//    e.g.: "data source already pruned / this id is too old, retry with the archive endpoint or a more recent id".
```

How to extract the subset — keep only the fields the assertions need, store nothing else:

```dart
final fixture = {
  'id': id,
  'payload': {                    // ← extract only the fields decode / assertion will read
    'messages': raw['messages'],
    'preState': raw['preState'],
    'postState': raw['postState'],
    // …discard all other fields in the raw response
  },
};
File(outPath).writeAsStringSync(JsonEncoder.withIndent('  ').convert(fixture));
```

The **batch fetch script** handles the reality of "public / heavily rate-limited endpoints", with three reusable points:

```bash
# tools/fetch_fixtures.sh
ENDPOINTS=( "https://ep1..." "https://ep2..." )   # ① endpoint pool: rotate to lower the chance of being throttled

next_endpoint() { local ep="${ENDPOINTS[$EP_IDX]}"; EP_IDX=$(((EP_IDX+1)%${#ENDPOINTS[@]})); echo "$ep"; }

call_with_retry() {                               # ② retry on failure, lengthening the interval each time
  local a=1; while [ "$a" -le 3 ]; do
    dart run tools/fetch_cli.dart "$@" "--endpoint=$(next_endpoint)" 2>&1 && return 0
    sleep $((a*15)); a=$((a+1))
  done; return 1
}

out="$ROOT/$src/$(printf '%02d' "$idx").json"
[ -f "$out" ] && { echo "skip $out"; continue; }  # ③ skip if artifact already exists = resumable fetching
call_with_retry dump "$id" "--out=$out"; sleep 5   # also sleep between each call, don't hammer the data source
```

Tying the three points together: **endpoint-pool rotation + retry with lengthening interval + skip if artifact already exists (resumable fetching)** — if throttled / disconnected halfway, rerunning the script picks up where it left off and doesn't re-fetch what's already there.

**Artifact layout**: `test/<module>/fixtures/<source>/01.json`, `02.json`… one directory per source, a few entries per source, covering normal + every dirty / boundary case you can think of.

---

### Strategy B: hand-built byte fixtures (test binary / protocol decode, zero network)

**When to use**: the subject under test is a **decoder / parser** that eats a **byte stream** and parses it by layout — a custom binary format, protobuf-like, on-chain events, Bluetooth / serial packets, file headers. For this kind you **simply shouldn't fetch the network**: build the bytes straight from the protocol table, fully deterministic, and you can craft arbitrary boundary / malformed inputs (truncated, out-of-bounds, misaligned).

**How**: a set of small helper functions write each type as little-endian bytes, use `BytesBuilder` to assemble them in layout order, and the fixture class exposes `toBytes()`.

```dart
// test/<module>/_fixtures.dart
import 'dart:typed_data';

// little-endian encoding helpers (add i32 / u128 / string etc. as the protocol needs)
Uint8List _u64Le(BigInt v) {
  final b = ByteData(8);
  b.setUint32(0, (v & BigInt.from(0xFFFFFFFF)).toInt(), Endian.little);
  b.setUint32(4, (v >> 32).toInt(), Endian.little);
  return b.buffer.asUint8List();
}

/// Fixture for one event: build known input bytes → feed the decoder → assert the output
class EventFixture {
  final BigInt amount;
  final bool flag;
  const EventFixture({required this.amount, required this.flag});

  Uint8List toBytes() {
    final b = BytesBuilder();
    b.add(_discriminator);        // [0..8)   event type tag
    b.add(_u64Le(amount));        // [8..16)  ← annotate the [byte offset range], written against the protocol table
    b.addByte(flag ? 1 : 0);      // [16]     direction / flag bit
    return b.toBytes();           // skip padding if it doesn't affect decoding
  }
}
```

Test:

```dart
test('decode normal event', () {
  final bytes = const EventFixture(amount: BigInt.from(500), flag: true).toBytes();
  final ev = decoder.decode(bytes);
  expect(ev.flag, true);
  expect(ev.amount, BigInt.from(500));
});
```

Key points:
- **Annotate the byte offset range after each `add`**, written against the protocol table — when changing layout you align at a glance, no fumbling.
- **One fixture class per source / per protocol variant** (one for each different upstream format), covering multiple protocols.
- **Use `BigInt` for amounts / large integers, never `double`** — `double` loses precision at large magnitudes, which makes assertions falsely pass / fail.

---

### Strategy C: `forTesting` factory injecting a mock (test the service's control flow + error handling)

**When to use**: test the **control flow and failure handling** of a **service that depends on external IO** (network, DB, platform channels) — you don't care about the real IO result, only "when the dependency returns X / throws / times out, how does the service react".

**How**: the service exposes an `Xxx.forTesting(call: ...)` factory, making the external dependency an **injectable function**; the test simulates with closures: normal / error / throw / timeout / empty input.

The most worth-copying part is the **error-handling assertion paradigm** — when the dependency breaks, the service must not crash, must not leak internal exceptions up to callers, and must **collapse into a domain-internal neutral state the caller can handle** (e.g. `inconclusive`):

```dart
// normal pass-through
test('dependency err=null → ok', () async {
  final s = Service.forTesting(call: (_) async => _ok(data: ['ok']));
  expect((await s.run(input)).status, Status.ok);
});

// ★ external throws → collapse into a [neutral state], don't leak the internal error (StateError) up to callers
test('external throws → inconclusive', () async {
  final s = Service.forTesting(call: (_) => Future.error(StateError('source down')));
  final r = await s.run(input);
  expect(r.status, Status.inconclusive);   // not failed, and not re-throwing the exception
  expect(r.rawErr, isNull);                // internal error not leaked
});

// ★ timeout also goes through the same neutral branch
test('timeout → inconclusive', () async {
  final s = Service.forTesting(call: (_) => Completer<R>().future);  // hangs forever
  expect((await s.run(input, timeout: const Duration(milliseconds: 30))).status,
         Status.inconclusive);
});
```

This layer nails down **robustness** specifically: "when the dependency breaks, the service doesn't crash, doesn't leak internal exceptions, collapses into a neutral result" — this is exactly what on-device testing struggles to reproduce reliably, yet is the most likely source of production incidents.

---

### Strategy D: probe scripts (one-off exploration, not regression tests)

**When to use**: you're unsure what "a certain numeric / precision / boundary actually looks like under the **real distribution**", and want to set the implementation by data rather than gut feel.

**How**: write a one-off `dart run` script, pull real samples + run statistics (median / p90 / p99 / significant digits), **write the conclusion into a code comment or doc**, and keep the script in `tools/` for reference.
e.g.: probe out "at a certain magnitude `double` has only 4–6 significant digits, everything after `toStringAsFixed(12)` is noise" → set the numeric representation and formatting strategy accordingly.

> **probe ≠ regression**: a probe is **exploration** (answering "what is reality like"), run once to get a conclusion; a unit test is **regression** (locking down "what the logic must be"), run on every CI.
> **Don't leave a probe script in the test suite as regression** — it depends on real data / network, which makes the suite slow and non-deterministic. Once the conclusion is moved into a comment, the script goes to `tools/`.

---

## 4. Layer ②: widget test — the fast regression net for interaction logic

**When to use**: verifying **widget interaction, navigation, form validation, conditional rendering, and empty/error/loading states**. These get assigned to the device layer by default, but the vast majority don't depend on the real rendering pipeline and can be proven inside `testWidgets` in milliseconds.

**The criterion (use this to split device layer from this layer)**: ask "does this *require* real GPU rendering / a real system capability / real backend data?"

| Answer | Belongs to |
|---|---|
| Not required (did state/copy/route change after the tap, is the disabled state right, did the error message appear) | **this layer ②** (locked down long-term as a regression net) |
| Required (real rendering aesthetics, native plugins/camera/push, real network and accounts, platform differences) | the device layer |

> ⚠️ **This table decides "which layer owns the regression net", not "whether to go look on a device"**. The same interaction can perfectly well be done on both sides: a widget test locks the behavior against regression **while** you also tap it on a real device to confirm how it looks and behaves there. **If you changed UI this time, you still go look on a device** — a passing widget test only means the logic isn't wrong, not that it works well on a real device.

```dart
testWidgets('tapping submit navigates to home', (tester) async {
  await tester.pumpWidget(const MyApp());
  await tester.enterText(find.byKey(const Key('email_input')), 'a@b.com');
  await tester.tap(find.byKey(const Key('submit_btn')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('home_screen')), findsOneWidget);
});
```

Key points:
- **Share the same `Key`s with Patrol** — SKILL's code contract (the `Key` + `Semantics` double tag) pays off directly at this layer; no second locator scheme needed.
- `pumpAndSettle()` runs out all animation frames; when unsure use it rather than hand-writing a `Duration` wait.
- **Screen size is controllable**: set `tester.view.physicalSize` / `devicePixelRatio` to the target model, with `addTearDown(tester.view.reset)` to restore — **small-screen overflow reproduces at this layer**, no real device needed.
- Displace network/storage dependencies with layer ①'s `forTesting` injection (Strategy C); don't let a widget test touch real IO.
- **Failure messages are more readable than the device layer's**: you get `found 0 widgets` plus the widget tree at that moment, no screenshot guessing.

---

## 5. Layer ③: golden matrix + a11y guideline — machine judgment for visuals and contracts

### 5.1 golden: stop doing visual regression by eyeballing screenshots

**Why it's worth it**: having a human or an AI stare at full screenshots to judge "does this look right" is slow and unreliable. A golden gives you **a quantified number plus an image of only the changed region**:

```
Golden "goldens/home_light_x1.0.png": Pixel test failed, 0.32%, 3619px diff detected.
Failure feedback can be found at .../test/failures
```

On failure it writes **four artifacts**; `*_isolatedDiff.png` is the one to look at — **it paints only the changed pixels**, so you see at a glance what moved, far cheaper than reading a full screenshot:

| Artifact | What it is |
|---|---|
| `*_masterImage.png` | the baseline |
| `*_testImage.png` | what this run actually produced |
| `*_isolatedDiff.png` | **only the changed region** (Read this one first) |
| `*_maskedDiff.png` | the changes overlaid on the actual image |

**Make it a matrix**: one `flutter test` covers the "theme × font scale × screen size" combinations, **covering in seconds what would take dozens of manual passes**:

```dart
for (final brightness in [Brightness.light, Brightness.dark]) {
  for (final scale in [1.0, 1.5]) {
    testWidgets('golden ${brightness.name}_x$scale', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: MaterialApp(theme: ThemeData(brightness: brightness), home: const HomeScreen()),
      ));
      await tester.pumpAndSettle();
      await expectLater(find.byType(HomeScreen),
          matchesGoldenFile('goldens/home_${brightness.name}_x$scale.png'));
    });
  }
}
```

Usage and traps:
- **Create the baseline**: `flutter test --update-goldens`. **Baselines are assets committed to the repo** and reviewed alongside code — a changed baseline *is* a visual change, and it's visible in the diff.
- **`--update-goldens` means "accept how it looks now"**, not "fix the failure". On failure, **read `isolatedDiff` first to decide whether this change was intended**, and only then update the baseline. Blindly running `--update-goldens` is exactly SKILL's "editing tests to dodge assertions".
- **Font rendering differs across machines**: compare in the same kind of environment where the baseline was generated, or you'll get meaningless whole-screen diffs.
- Pin `devicePixelRatio` and `physicalSize`; don't let defaults drift with the environment.

### 5.2 a11y guideline: make the "testable by construction" contract get caught automatically

SKILL's code contract requires interactive widgets to be wrapped in `Semantics`. That **doesn't need a human self-check** — `flutter_test` ships four assertable guidelines, sub-second and device-free:

```dart
testWidgets('accessibility contract self-check', (tester) async {
  final handle = tester.ensureSemantics();          // must be enabled first, disposed at the end
  await tester.pumpWidget(const HomeScreen());
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));   // tappable widgets must have a label
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));   // hit area ≥ 48x48
  await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));       // hit area ≥ 44x44
  await expectLater(tester, meetsGuideline(textContrastGuideline));       // contrast meets WCAG
  handle.dispose();
});
```

The failure messages are directly actionable (measured shape):

```
expected tappable node to have semantic label, but none was found.
  SemanticsNode#6(Rect.fromLTRB(360.0, 320.5, 440.0, 400.5), actions: [tap])

expected tap target size of at least Size(48.0, 48.0), but found Size(20.0, 20.0)

Expected contrast ratio of at least 4.5 but found 1.29 for a font size of 14.0.
```

**Why this matters especially for this skill**: `labeledTapTargetGuideline` catches exactly the case of "a `GestureDetector`/`InkWell` with no `Semantics` wrapper" — the **root cause** of `dump ui` not listing a widget in SKILL. With this assertion in place the problem is caught at the offline layer, so **you don't discover "this widget can't be tapped" only after you're on a device**. It turns element-driven interaction's precondition into a CI gate.

> `ensureSemantics()` is only needed **in tests**; **don't change app code for it** — calling `SemanticsBinding.instance.ensureSemantics()` inside the app does nothing for `dump ui` (measured; see `vm-service.md` §5).

---

## 6. Directory convention & how to run

```
tools/
  fetch_cli.dart          # pure-Dart fetch CLI (no flutter dependency): list / dump subcommands
  fetch_fixtures.sh       # batch fetch (endpoint-pool rotation + retry with lengthening interval + resumable fetching)
  probe_*.dart            # one-off exploration scripts (probe, not in the regression suite)
test/
  <module>/_fixtures.dart           # Strategy B: byte fixture builders (toBytes)
  <module>/fixtures/<source>/*.json # Strategy A: real-data JSON fixtures, one directory per source
  <module>/xxx_test.dart            # unit tests using fixtures / forTesting (Strategies A/B/C)
  <module>/xxx_widget_test.dart     # layer ②: interaction/navigation (testWidgets)
  goldens/*.png                     # layer ③: visual baselines,【commit these to the repo】
  failures/                         # golden failure artifacts,【add to .gitignore】
```

Run:
- `flutter test` — runs everything (①②③ in one shot, including whatever needs the flutter binding).
- `dart test` — runs the **pure-Dart part** (decode / parse / numerics not depending on the flutter binding), **faster**; prefer it for pure-logic modules.
- `flutter test --update-goldens` — run it **only after confirming the visual change is intended** (see §5.1).

**When running autonomously, use machine-readable output instead of parsing console text**:

```bash
flutter test --reporter json                     # machine-readable result stream
flutter test --file-reporter json:reports/t.json # results to a file, parse after the run
flutter test --coverage                          # produces coverage/lcov.info — use it to see【what isn't covered yet】
```

How to use `--coverage` in an autonomous loop: not to hit a coverage number, but to **answer "which branch haven't I verified yet"**, and decide what test to write next from that — more accurate than guessing.

CI-friendly: no device needed, deterministic, sub-second — fit to run on every push, leaving on-device verification for critical paths / nightly.

---

## 7. Hard-principle summary

1. **Offline-green ≠ the UI is verified** (the most important one): these three layers run headless and cannot prove how it renders on a real device. If you changed UI, or the task said "run it and see", **you must go to the device and verify by screenshot** — this skill's output is that screenshot, not a green `flutter test`.
2. **Don't spend real-device time on pure-logic bugs**: parse/numeric/null-deref issues are pinpointed to the line in seconds offline; leave repeatedly-run static visual regression to goldens. This is an **efficiency optimization** and ranks below principle 1.
3. **`--update-goldens` is not a fix**: on failure read `isolatedDiff` first to judge whether the change was intended, and only then update the baseline — blind updates equal editing tests to dodge assertions.
4. **`meetsGuideline(labeledTapTargetGuideline)` is element-driven interaction's gate**: make "this widget has no Semantics wrapper" fail offline instead of discovering on a device that you can't tap it.
5. **When the dependency breaks, don't crash, don't leak internal exceptions**: external throw / timeout both collapse into a domain-internal neutral state (`inconclusive`), don't leak the internal error, don't throw, don't treat it as `failed` (Strategy C).
6. **A fixture extracts only the minimal field subset the assertions need**, don't store the full payload; on fetch failure give an actionable error (Strategy A).
7. **For byte fixtures, annotate the byte offset range after each add**, written against the protocol table (Strategy B).
8. **Use `BigInt` for amounts / large integers, not `double`** (Strategy B).
9. **probe ≠ regression**: take the conclusion from the exploration script into a comment, don't leave it in the test suite (Strategy D).
10. **Get the offline layer all green before going on-device**; `flutter test` failing = a logic/contract bug — fix it directly without going on-device.

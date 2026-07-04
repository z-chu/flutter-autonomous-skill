# Offline / fixture sub-second test layer (lower layer)

> This doc is a deep dive into **Layer ①** of `flutter-autonomous`'s "four verification layers"; terminology/principles defer to [SKILL.md](../SKILL.md) and must not contradict it.
> SKILL already covers the "closed-loop order", "four red lines", "self-repair ≤5 rounds", "on assertion failure fix the implementation", etc.; here we only fill in what SKILL doesn't expand on — **how the offline layer builds data, how to inject it, where to put it, and how to run it**.

---

## 1. Why this layer beyond on-device (the two layers complement each other)

The on-device layer (element-driven + Patrol + screenshots) is in essence **integration + visual**: slow, needs a device, and **non-deterministic** (networked, external data shifts, timing-sensitive, animated). It can't prove — and shouldn't be used to prove — issues like:

- "When this parser eats dirty/malformed data, is the output correct?"
- "When this service that depends on external IO has its dependency throw / time out, does it crash, or does it leak the internal error up to callers?"
- "Is the precision of this numeric computation good enough at some magnitude?"

These are all **pure logic**, and should have a dedicated layer to lock them down: **offline, deterministic, sub-second, no device, CI-friendly**. The two layers each cover one segment and complement each other:

| Layer | What it locks | Traits |
|---|---|---|
| **Offline / fixture layer** (this doc) | Pure logic: decode / parse / numerics / state machine / error handling | Freezes the outside world into deterministic input; sub-second, no device, runnable on every push |
| **On-device / Patrol layer** (main SKILL body) | Integration + visual: interaction, navigation, rendering, connectivity, layout | Needs a device, slow, verifies things only a real device can verify |

Mantra: **logic that can be proven offline must never go on-device**. Save device time for the integration and visual things only a real device can verify.

---

## 2. Where it slots into the closed loop

The offline layer sits after `flutter analyze` and before going on-device:

```
flutter analyze (zero warnings)
  → flutter test / dart test   ← [offline layer: this doc] sub-second, deterministic, no device
        └─ failing = pure-logic bug, [don't go on-device, fix directly]
  → confirm device online → element-driven (one-shot dump→tap)
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

## 4. Directory convention & how to run

```
tools/
  fetch_cli.dart          # pure-Dart fetch CLI (no flutter dependency): list / dump subcommands
  fetch_fixtures.sh       # batch fetch (endpoint-pool rotation + retry with lengthening interval + resumable fetching)
  probe_*.dart            # one-off exploration scripts (probe, not in the regression suite)
test/
  <module>/_fixtures.dart           # Strategy B: byte fixture builders (toBytes)
  <module>/fixtures/<source>/*.json # Strategy A: real-data JSON fixtures, one directory per source
  <module>/xxx_test.dart            # unit tests using fixtures / forTesting (Strategies A/B/C)
```

Run:
- `flutter test` —— runs everything (including those needing the flutter binding).
- `dart test` —— runs the **pure-Dart part** (decode / parse / numerics not depending on the flutter binding), **faster**, prefer it for pure-logic modules.

CI-friendly: no device needed, deterministic, sub-second — fit to run on every push, leaving on-device verification for critical paths / nightly.

---

## 5. Hard-principle summary

1. **When the dependency breaks, don't crash, don't leak internal exceptions**: external throw / timeout both collapse into a domain-internal neutral state (`inconclusive`), don't leak the internal error, don't throw, don't treat it as `failed` (Strategy C).
2. **A fixture extracts only the minimal field subset the assertions need**, don't store the full payload; on fetch failure give an actionable error (Strategy A).
3. **For byte fixtures, annotate the byte offset range after each add**, written against the protocol table (Strategy B).
4. **Use `BigInt` for amounts / large integers, not `double`** (Strategy B).
5. **probe ≠ regression**: take the conclusion from the exploration script into a comment, don't leave it in the test suite (Strategy D).
6. **Get the offline layer all green before going on-device**; `flutter test` failing = pure-logic bug, fix directly without going on-device.

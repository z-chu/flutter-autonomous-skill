---
description: Expand a one-line requirement into assertable acceptance criteria, then implement only after confirmation (pure thinking, no code)
argument-hint: [one-line requirement]
---

I want to implement: $ARGUMENTS

First, **do not write any code, do not touch files, do not go on-device**. This step only produces an executable acceptance contract; only after I reply "confirm / start" do we enter implementation.
Terminology, locator priority, and the Key+Semantics dual-tagging convention all align with the `flutter-autonomous` skill; this command does not restate the methodology, it only produces the expansion of this requirement.

---

### User story
Who (user role) is on which page, does what action, and expects what result. State the value in one sentence.

### Automatically verifiable acceptance criteria (3~8 items)

Each must be **assertable** — preferably re-runnable by Patrol via `Key`, otherwise verifiable one-shot via element-driven (`dump ui` lists the `Semantics` label). Format:

- **Action**: find `Key('xxx')` or label "xxx" → tap / type / scroll to / wait
- **Expected**: some widget appears / disappears / text becomes xxx / navigates to page xxx (use the page-root `Key` to judge whether on a given page)

> An item that cannot be written as "Action→Expected" is unverifiable — either break it down, or move it to the "Manual verification items" below.

### Boundary / edge cases
List, item by item, the boundaries to handle, each with a corresponding acceptance expectation: network error, empty data / empty list, loading, permission denied, input validation, timeout fallback, etc. **List only what really happens**; do not design error handling for impossible scenarios.

### At which layer should this requirement be verified (think it through before starting)
- Pure logic (parsing / numerics / state machine / error handling) → mark "offline fixture"; list the ones that can be locked down in seconds via `flutter test` without going on-device.
- Interaction / navigation / conditional rendering → can be marked "widget test" to weave a long-term regression net (**this does not replace looking at it on a device**).
- Repeated visual regression across theme × font scale → can be marked "golden".
- Must be verified on a real device / simulator (real rendering, real-device interaction timing, system integration, real data) → mark "device layer".
- Connection / state machine / gating → mark "evidence from logs".

> **If this requirement touched UI at all, at least one acceptance criterion must land in "device layer: run it for real + verify by screenshot"**. Offline all-green cannot prove it works well on a real device — it runs headless, without the real rendering pipeline.

### List of widgets that need Key + Semantics added / supplemented
Every interactive or assertable widget that enters the acceptance criteria goes in the table; custom gesture widgets (`Touchable`/`GestureDetector`/`InkWell`) must explicitly wrap `Semantics`, otherwise `dump ui` won't list them — flag these separately.

| Key name (`<feature>_<widget type>`) | Widget type | Semantics label | Purpose / corresponding acceptance criterion |
|--------|---------|-----------------|------|
| `login_submit_btn` | ElevatedButton | from text | Triggers login, criterion 1 |
| `error_text` | Text | from text | Shows error message, criterion 3 |
| `home_screen` | Scaffold (page root) | — | Judge navigation to home, criterion 2 |
| `swap_slide_btn` | GestureDetector (must explicitly wrap Semantics) | `Slide to buy` | Custom-drawn slider, criterion 4 |

### Files involved
- `lib/.../xxx.dart`: create / modify + one-line note on what changes
- `integration_test/<feature>_test.dart`: create Patrol test case (matching the acceptance criteria above)
- `test/.../xxx_test.dart`: if there is offline-lockable pure logic, list the fixture unit tests

### Manual verification items (not automatically assertable)
List the eyeball-only ones: visual look, animation feel, copy wording, etc. These go through screenshots, not Patrol.

---

After output, **stop and wait for my confirmation**. Do not enter implementation until I reply "confirm / start".
If the requirement itself is ambiguous (missing key info, unclear which page to navigate to, unclear UI, unclear platform), **ask first before expanding** — do not silently decide for me.

# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-08-16

### Changed

- **Red lines are now deny-by-default.** Spending real money, touching secrets or
  credentials, and irreversible destruction are never performed unless the user
  has authorized them upfront — in the run's instructions, or via
  `{{AUTHORIZED_REDLINE_EXCEPTIONS}}` in the project `CLAUDE.md`, and only within
  the stated scope. Unattended runs skip an unauthorized red-line action, mark
  "authorization needed" in the report, and move on instead of waiting for a human.
- **The four red lines are no longer blockchain-specific.** They are stated in
  general terms (payments/orders, credentials, irreversible destruction) with
  on-chain transactions as one example among many; project-specific red lines go
  in `{{IRREVERSIBLE_REDLINES}}`.
- **Slimmer skill description.** The description is the skill's only
  permanently-loaded text, so it now carries trigger conditions only — the
  methodology it used to repeat lives in the skill body. Also dropped
  "packaging", a trigger word with no matching content in the skill.
- **Deduplicated the skill body.** Committing, the red lines, and the report
  requirements each had two or three full copies; each now has a single
  authoritative home, with the Rules block reduced to a pure checklist.
- **Introduced "green zone"** as the counterpart to "red line" — everything
  reversible and low-risk (installing tools, local config, dependencies,
  scaffolding) that the agent should just finish and keep going, replacing six
  separate spellings-out of the same rule.
- **Report requirements are now a five-item completion bar** at the end of the
  autonomous loop, so the loop's final step has a checkable bound.
- **Section numbering fixed** — two sections previously both claimed to be the
  first step. Context gathering is §1, environment bootstrap is §2, and the
  device lookup states its dependency on the bootstrap explicitly.
- **`references/tool-decision-tree.md`** no longer caches the full `mobilecli`
  command surface. It keeps the traps and usages `mobilecli --help` cannot tell
  you, and points at `--help` for the rest.

### Fixed

- The README install badge is a static link until skills.sh install stats
  aggregate.

## [1.0.0] - 2026-08-14

### Added

- Initial release: autonomous Flutter on-device testing skill for Claude Code.
- Element-driven interaction over Semantics labels via `mobilecli`, replayable
  Patrol assertions by `Key`, an offline fixture test layer, screenshot and log
  verification, and an unattended implement → test → fix → commit loop.
- iOS (simulator first, WebDriverAgent for real devices) and Android (adb) at
  parity, with platform detail in `references/{ios,android}.md`.
- Project templates: a `CLAUDE.md` constitution, a permission allowlist with
  format/analyze hooks, and `/spec`, `/verify`, `/ship`, `/debug`, `/nightly`
  commands.
- Full English mirror under `skills/flutter-autonomous/en/`.

# Bootstrapping under a restricted network or restricted permissions

> An expansion of keystone (`../SKILL.md`) §2. **Directions, not recipes** — you can write the commands yourself; this only holds the few things you can't guess, and that cost extra rounds when guessed wrong.

---

## The test: channel or permission

- **Channel problem** (a package source is blocked): **still green zone**, switch routes and keep going. The green zone is defined by the goal, not the channel — one route being blocked ≠ can't be done.
- **Permission problem** (only a human can grant it in a GUI — macOS Accessibility reporting `-1719`, "Allow USB debugging" on the device, iOS Developer Mode, the `xcode-select --install` prompt): **genuinely stop**, same tier as a physically disconnected device. An interactive session asks once; unattended, skip the item, mark "manual authorization needed: <where to click what>" in the report, and move to the next task.

Getting it backwards is asymmetrically expensive: channel-as-permission wastes a stop-and-ask round you could have routed around; permission-as-channel burns your self-fix rounds on a dead end. **One `curl` probe is cheaper than guessing.**

---

## What you can't guess when npm is blocked

> `bash scripts/bootstrap.sh` already handles mobilecli and jq (falling back to GitHub Releases when npm/brew is blocked). The below is only needed when **the script itself reports both channels blocked**.

1. **`npx` is not a fallback** — it hits the same registry as `npm i -g`, so if npm is blocked, npx is too. Building from source with `make build` needs a Go toolchain, which is equally a dead end on a machine without one. These two are the easiest wasted attempts.
2. **A corporate gateway domain in the error, or an HTML block page as the response body, means network policy** — not something you can configure away. Don't burn rounds on `NODE_OPTIONS=--use-system-ca`, registry swaps, or disabling `strict-ssl`; switch channels instead.
3. **What GitHub Releases can rescue**: `mobile-next/mobilecli` (zip) and `jqlang/jq` (bare static binary, no unzip). When resolving the URL, **match a platform keyword against the real asset list rather than reconstructing the filename** — upstream renaming (a `v` prefix, `darwin`/`amd64` spellings) breaks the reconstructed path. Unauthenticated `api.github.com` is rate-limited (403 once exceeded), while the `releases/latest` redirect yields the tag without that limit and makes a good fallback.
4. **What can't be rescued, so don't burn time on it**: mobile-mcp and mobilewright are npm packages — no release assets, and cloning the source still needs `npm install` for dependencies. mobilecli already covers the interaction base, and MCP config changes only take effect next session anyway. **patrol_cli lives on pub.dev, a channel independent of npm** — npm being blocked does not imply pub is, so just try `dart pub global activate patrol_cli` first.
5. **Still `permission denied` after downloading on macOS**: besides `chmod +x`, you need `xattr -d com.apple.quarantine` — anything fetched with `curl` carries the Gatekeeper quarantine attribute, and missing this step reads as a failed install.
6. **PATH does not persist across Bash calls**: after installing into `~/.local/bin`, **every** subsequent command needs the `export PATH="$HOME/.local/bin:$PATH";` prefix. To avoid that, install into a directory already on PATH, or add it to the shell rc — but **editing the user's shell rc changes their environment, so ask first**.

> **Scope**: this covers **a blocked package source** only (in practice, npm and its kind). Xcode, the Android SDK, adb, and Google's or Apple's distribution domains are **out of scope** — a company blocking those would stop its own developers from working.

---

## When a layer is blocked: degrade, don't stop the run

Keep the layers that still run, and state in the report **which layer was blocked by what, and whether the blocker was a channel or a permission**:

- Device interaction won't install → the offline layer still runs (`flutter test` needs neither device nor network, and its assertion coverage is usually higher than you'd expect).
- Patrol won't install → prove the feature with element-driven interaction + screenshots now, and add regression cases once the channel opens.
- A gesture won't register (e.g. a WDA-synthesised long press that Flutter ignores) → **prefer fixing the code so it becomes testable** (swap it for a tappable control carrying `Semantics`); same principle as the keystone's "won't list = fix it in code", and it improves manual testing too.

Never write "the environment wouldn't allow it" as "verified", and never stop the whole run because one layer couldn't run.

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# flutter-autonomous · environment bootstrap (cross-platform mac/Linux, idempotent)
#
# First thing on entering autonomous mode: complete the toolchain — whatever can be
# installed/configured automatically must never stop and ask a human.
# Every item follows: detect → install if missing → verify with a separate command →
# skip if already present. Safe to re-run; failures do not accumulate.
#
# Red lines (this script never touches them; forbidden by default, allowed only with the
# user's explicit prior authorization):
#   ① device physically disconnected/unplugged   ② anything that spends real money (payments/charges/transfers/on-chain)
#   ③ key/credential operations (production keys/private keys/user credentials)   ④ irreversible destruction (deleting data/changing production)
# This script only performs reversible, low-risk local installation and configuration;
# it deletes no data, changes no production, and touches no funds on the device.
#
# Exit codes: 0 = everything ready or auto-fixed; non-zero = something "needs a human"
#             (see the summary at the end).
# ─────────────────────────────────────────────────────────────────────────────
set -u   # no -e: a single failed item must be recorded and the run continue, not abort the script

# ── Colors (degrade to empty strings without a TTY, so logs stay clean) ───────
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_FIX=$'\033[33m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=''; C_FIX=''; C_BAD=''; C_DIM=''; C_RST=''
fi

# ── Platform detection ──────────────────────────────────────────────────────
OS="$(uname -s)"   # Darwin = mac; Linux = Linux
case "$OS" in
  Darwin) IS_MAC=1; IS_LINUX=0 ;;
  Linux)  IS_MAC=0; IS_LINUX=1 ;;
  *)      IS_MAC=0; IS_LINUX=0 ;;   # anything else (MSYS etc.) is treated as neither; iOS is skipped
esac

# ── Helpers ─────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }   # is the command on PATH

# Summary collection: one "status\tname\tdetail" line per item, printed together at the end
SUMMARY=""
NEED_MANUAL=0                  # any item needing a human → 1 → non-zero exit code
add_ok()     { SUMMARY="${SUMMARY}OK\t$1\t$2\n"; }
add_fix()    { SUMMARY="${SUMMARY}FIX\t$1\t$2\n"; }
add_bad()    { SUMMARY="${SUMMARY}BAD\t$1\t$2\n"; NEED_MANUAL=1; }
add_skip()   { SUMMARY="${SUMMARY}SKIP\t$1\t$2\n"; }

# Section heading
section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_RST"; }
# Progress log (does not go into the summary)
log()  { printf '   %s\n' "$1"; }

# ── Make sure ~/.pub-cache/bin is on PATH (where patrol_cli / dart pub global land) ──
PUB_CACHE_BIN="${PUB_CACHE:-$HOME/.pub-cache}/bin"
ensure_pubcache_path() {
  case ":$PATH:" in
    *":$PUB_CACHE_BIN:"*) : ;;                       # already on PATH
    *) export PATH="$PATH:$PUB_CACHE_BIN" ;;          # add it for this process, so sub-commands work right away
  esac
}
ensure_pubcache_path

echo "${C_DIM}Platform: $OS  |  pub-cache bin: $PUB_CACHE_BIN${C_RST}"

# ─────────────────────────────────────────────────────────────────────────────
# node (npx depends on it; v22+ required). If missing, only advise — never force-install
# (everyone uses a different version manager).
# ─────────────────────────────────────────────────────────────────────────────
section "node"
if have node; then
  NODE_RAW="$(node -v 2>/dev/null || echo '?')"          # e.g. v22.3.0
  NODE_MAJOR="$(printf '%s' "$NODE_RAW" | sed -E 's/^v?([0-9]+).*/\1/')"
  if [ "${NODE_MAJOR:-0}" -ge 22 ] 2>/dev/null; then
    log "node $NODE_RAW (>= v22)"
    add_ok "node" "$NODE_RAW"
  else
    log "node $NODE_RAW is below v22 — npx/mobilecli/mobile-mcp may be unstable"
    log "  Upgrade with: fnm install 22 && fnm use 22   or   nvm install 22 && nvm use 22"
    add_bad "node" "found $NODE_RAW, need v22+; upgrade with fnm/nvm"
  fi
else
  log "node not found. npx/mobilecli/mobile-mcp all depend on it."
  log "  Suggested install (version manager; not forced):"
  log "    fnm:  curl -fsSL https://fnm.vercel.app/install | bash  &&  fnm install 22"
  log "    nvm:  https://github.com/nvm-sh/nvm  &&  nvm install 22"
  add_bad "node" "missing; install v22+ with fnm/nvm"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Flutter SDK. If missing, only point at the installer — the SDK is not downloaded
# automatically (it is large and everyone puts it somewhere different).
# ─────────────────────────────────────────────────────────────────────────────
section "flutter"
if have flutter; then
  FLUTTER_VER="$(flutter --version 2>/dev/null | head -n1 || echo 'flutter (version unknown)')"
  log "$FLUTTER_VER"
  add_ok "flutter" "$FLUTTER_VER"
else
  log "flutter not found. Install the Flutter SDK and put it on PATH:"
  log "  https://docs.flutter.dev/get-started/install"
  log "  Once installed, run flutter doctor; toolchain constraints (JDK/Xcode versions) are read from the project CLAUDE.md."
  add_bad "flutter" "missing; install the SDK by hand (see flutter.dev)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# mobilecli (the interaction base: dump ui / io tap, no MCP and no restart needed).
# Channel 1: global npm install. Channel 2: the Go binary from GitHub Releases.
# Corporate DLP gateways often block the npm registry while letting GitHub through —
# in that case channel 2 is the only way in.
# Note that npx and npm i -g go through the same registry, so npx is not a fallback
# and is no longer suggested as one.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# The GitHub Releases channel (generic) — the backup route when npm/brew is blocked by a
# corporate gateway. It only addresses [a blocked package source] (in practice, npm and
# friends); the distribution channels of Xcode/Android SDK/Google/Apple are out of scope —
# if a company really blocked those, their own developers could not work either.
# Auto-fallback covers: mobilecli, jq (both ship prebuilt artifacts on upstream Releases).
# Beyond rescue: mobile-mcp, mobilewright (npm packages with no release assets — cloning
# them still requires npm install to pull dependencies), and patrol_cli (published to
# pub.dev, an independent channel: npm being blocked does not imply it is).
# ─────────────────────────────────────────────────────────────────────────────
LOCAL_BIN="$HOME/.local/bin"

# Latest tag: follow the releases/latest redirect — no API, so no unauthenticated rate limit.
gh_latest_tag() {
  curl -sSLI -m 20 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$1/releases/latest" 2>/dev/null | sed 's#.*/tag/##'
}

# gh_asset_url <repo> <asset-name-keyword> → echoes the download URL; non-zero on failure.
# Always [matches against the real asset list] rather than guessing a filename — so an
# upstream rename (adding a v prefix, switching to darwin/amd64 spelling) does not break it.
gh_asset_url() {
  local repo="$1" pat="$2" tag name url
  tag="$(gh_latest_tag "$repo")"; [ -n "$tag" ] || return 1
  # ① the expanded_assets fragment: no API, no rate limit, and it returns the real asset names
  name="$(curl -sSL -m 20 "https://github.com/$repo/releases/expanded_assets/$tag" 2>/dev/null \
          | grep -oE 'href="[^"]*/download/[^"]*"' | sed 's#.*/##;s/"$//' \
          | grep -- "$pat" | head -1)"
  [ -n "$name" ] && { echo "https://github.com/$repo/releases/download/$tag/$name"; return 0; }
  # ② fall back to the API (rate-limited when unauthenticated; returns 403 once exceeded)
  url="$(curl -sSL -m 20 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
         | grep -o '"browser_download_url": *"[^"]*'"$pat"'[^"]*"' | head -1 | cut -d'"' -f4)"
  [ -n "$url" ] && { echo "$url"; return 0; }
  return 1
}

# Two things always need fixing after such an install: files out of a zip have no execute bit,
# and on mac anything fetched with curl carries the Gatekeeper quarantine attribute.
fix_downloaded_bin() {
  chmod +x "$1" 2>/dev/null
  [ "$IS_MAC" -eq 1 ] && xattr -d com.apple.quarantine "$1" 2>/dev/null
  return 0
}

# gh_install <repo> <asset-keyword> <command-name-to-install> [zip]
#   Pass "zip" as the 4th argument when the asset is an archive (unpack, then find the
#   same-named executable inside); otherwise it is treated as a bare binary.
gh_install() {
  local repo="$1" pat="$2" bin="$3" kind="${4:-bare}" url tmp found
  have curl || { log "  no curl, the GitHub channel is unavailable"; return 1; }
  url="$(gh_asset_url "$repo" "$pat")" || { log "  no asset matching '$pat' in the latest release of $repo"; return 1; }
  log "  downloading $url"
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$LOCAL_BIN"
  if [ "$kind" = zip ]; then
    have unzip || { log "  no unzip, cannot unpack"; rm -rf "$tmp"; return 1; }
    curl -sSL -m 180 -o "$tmp/a.zip" "$url" || { rm -rf "$tmp"; return 1; }
    unzip -oq "$tmp/a.zip" -d "$tmp/x"      || { rm -rf "$tmp"; return 1; }
    found="$(find "$tmp/x" -name "$bin" -type f 2>/dev/null | head -1)"
    [ -n "$found" ] || { log "  $bin not found inside the archive"; rm -rf "$tmp"; return 1; }
    cp "$found" "$LOCAL_BIN/$bin" || { rm -rf "$tmp"; return 1; }
  else
    curl -sSL -m 180 -o "$LOCAL_BIN/$bin" "$url" || { rm -rf "$tmp"; return 1; }
  fi
  rm -rf "$tmp"
  fix_downloaded_bin "$LOCAL_BIN/$bin"
  export PATH="$LOCAL_BIN:$PATH"            # usable immediately in this process (note: does not persist across shells)
  have "$bin"
}

# ~/.local/bin may already hold an artifact while not being on PATH — add it first, to avoid reinstalling
case ":$PATH:" in *":$LOCAL_BIN:"*) : ;; *) [ -d "$LOCAL_BIN" ] && export PATH="$LOCAL_BIN:$PATH" ;; esac

# ─────────────────────────────────────────────────────────────────────────────
# jq — a hard dependency of scripts/tap-by-label.sh (without it, "tap by label in one step"
# is unusable). Upstream publishes bare static binaries that need no unpacking at all,
# making this the easiest one to fix when brew is unavailable.
# ─────────────────────────────────────────────────────────────────────────────
section "jq (required by tap-by-label.sh)"
if have jq; then
  log "$(jq --version 2>/dev/null || echo jq)"
  add_ok "jq" "$(jq --version 2>/dev/null || echo 'installed')"
else
  JQ_DONE=0
  if [ "$IS_MAC" -eq 1 ] && have brew; then
    log "jq not found, channel 1: brew install jq…"
    brew install jq >/dev/null 2>&1 && have jq && JQ_DONE=1
  elif [ "$IS_LINUX" -eq 1 ] && have apt-get; then
    log "jq not found, channel 1: apt-get install jq…"
    sudo -n apt-get install -y jq >/dev/null 2>&1 && have jq && JQ_DONE=1
  fi
  if [ "$JQ_DONE" -eq 1 ]; then
    log "installed and verified: $(jq --version 2>/dev/null)"
    add_fix "jq" "installed via package manager: $(jq --version 2>/dev/null)"
  else
    log "the package-manager channel is blocked, switching to channel 2: GitHub Releases (bare static binary)…"
    case "$(uname -s)/$(uname -m)" in
      Darwin/arm64)  JQ_PAT=macos-arm64 ;;
      Darwin/x86_64) JQ_PAT=macos-amd64 ;;
      Linux/aarch64) JQ_PAT=linux-arm64 ;;
      Linux/x86_64)  JQ_PAT=linux-amd64 ;;
      *)             JQ_PAT='' ;;
    esac
    if [ -n "$JQ_PAT" ] && gh_install jqlang/jq "$JQ_PAT" jq; then
      log "installed from GitHub Releases and verified: $(jq --version 2>/dev/null)"
      add_fix "jq" "installed from GitHub Releases (in $LOCAL_BIN)"
    else
      log "both channels are blocked. tap-by-label.sh will be unavailable (you can still dump ui → io tap by hand)."
      log "  Pick an artifact yourself: https://github.com/jqlang/jq/releases"
      add_bad "jq" "not installed; tap-by-label.sh unavailable, see references/restricted-network.md"
    fi
  fi
fi

section "mobilecli (interaction base)"
if have mobilecli; then
  MC_VER="$(mobilecli --version 2>/dev/null | head -n1 || echo 'mobilecli')"
  log "$MC_VER"
  add_ok "mobilecli" "$MC_VER"
else
  MC_DONE=0
  if have npm; then
    log "mobilecli not found, channel 1: global npm install…"
    if npm i -g mobilecli@latest >/dev/null 2>&1 && have mobilecli; then
      MC_VER="$(mobilecli --version 2>/dev/null | head -n1 || echo 'mobilecli')"
      log "installed and verified: $MC_VER"
      add_fix "mobilecli" "installed via npm i -g: $MC_VER"
      MC_DONE=1
    else
      log "the npm channel is blocked (permissions/network/corporate gateway). Switching to channel 2: GitHub Releases…"
    fi
  else
    log "no npm. Going straight to channel 2: GitHub Releases…"
  fi

  if [ "$MC_DONE" -eq 0 ]; then
    case "$(uname -s)/$(uname -m)" in
      Darwin/arm64)  MC_PAT=macos-arm64 ;;
      Darwin/x86_64) MC_PAT=macos-x64 ;;
      Linux/aarch64) MC_PAT=linux-arm64 ;;
      Linux/x86_64)  MC_PAT=linux-x64 ;;
      *)             MC_PAT='' ;;
    esac
    if [ -n "$MC_PAT" ] && gh_install mobile-next/mobilecli "$MC_PAT" mobilecli zip; then
      MC_VER="$(mobilecli --version 2>/dev/null | head -n1 || echo 'mobilecli')"
      log "installed from GitHub Releases and verified: $MC_VER"
      log "  ⚠ It lives in $LOCAL_BIN, which is not on the default PATH — prefix every later command with:"
      log "      export PATH=\"$LOCAL_BIN:\$PATH\"; mobilecli ..."
      add_fix "mobilecli" "installed from GitHub Releases: $MC_VER (needs export PATH=$LOCAL_BIN)"
    else
      log "both channels are blocked. Diagnose by hand:"
      log "  curl -sSL -m 10 -o /dev/null -w '%{http_code}\\n' https://github.com"
      log "  reachable → go to https://github.com/mobile-next/mobilecli/releases and pick your platform's artifact"
      log "  See references/restricted-network.md for details (backup channels / execute bit and quarantine on macOS)"
      add_bad "mobilecli" "both the npm and GitHub channels are blocked; see references/restricted-network.md"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# patrol_cli (replayable Dart VM assertions by Key). If missing → dart pub global activate.
# ─────────────────────────────────────────────────────────────────────────────
section "patrol_cli (replayable assertions)"
if have patrol; then
  PATROL_VER="$(patrol --version 2>/dev/null | head -n1 || echo 'patrol')"
  log "$PATROL_VER"
  add_ok "patrol_cli" "$PATROL_VER"
else
  log "patrol not found, trying dart pub global activate…"
  if have dart; then
    if dart pub global activate patrol_cli >/dev/null 2>&1; then
      ensure_pubcache_path                          # after activate, the artifact lands in pub-cache/bin
      if have patrol; then
        PATROL_VER="$(patrol --version 2>/dev/null | head -n1 || echo 'patrol')"
        log "installed and verified: $PATROL_VER"
        add_fix "patrol_cli" "installed via dart pub global activate: $PATROL_VER"
      else
        log "activate succeeded, but patrol is still not on PATH. Exported temporarily:"
        log "  export PATH=\"\$PATH:$PUB_CACHE_BIN\""
        log "  To make it permanent, add that line to your shell rc (~/.zshrc or ~/.bashrc)."
        add_bad "patrol_cli" "installed, but $PUB_CACHE_BIN must be added to your shell rc"
      fi
    else
      log "dart pub global activate patrol_cli failed (network?). Retry the same command by hand."
      add_bad "patrol_cli" "activate failed; run dart pub global activate patrol_cli by hand"
    fi
  else
    log "no dart (it ships with the Flutter SDK). Install flutter first, then re-run this script."
    add_bad "patrol_cli" "no dart; install the flutter SDK first"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# mobile-mcp (the MCP flavor, optional). Note: changing the MCP config only takes effect
# in the NEXT session; this session keeps using the already-installed mobilecli — do not
# fall back to blind coordinates just because MCP is not connected.
# ─────────────────────────────────────────────────────────────────────────────
section "mobile-mcp (MCP flavor, optional)"
if have claude; then
  if claude mcp list 2>/dev/null | grep -qi mobile; then
    log "mobile-mcp is registered (claude mcp list matches 'mobile')"
    add_ok "mobile-mcp" "registered"
  else
    log "mobile-mcp is not registered, trying claude mcp add…"
    if claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest >/dev/null 2>&1 \
       && claude mcp list 2>/dev/null | grep -qi mobile; then
      log "registered. Note: MCP config changes only connect in the next session."
      log "  Keep using mobilecli in this session (already installed, works now); do not fall back to blind adb because MCP is not connected."
      add_fix "mobile-mcp" "added; effective next session, mobilecli covers this one"
    else
      log "claude mcp add failed. Run it by hand:"
      log "  claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest"
      log "  (not fatal: mobilecli already covers the interaction base)"
      add_bad "mobile-mcp" "mcp add failed; add by hand (non-blocking, mobilecli covers it)"
    fi
  fi
else
  log "no claude CLI, skipping MCP registration (mobilecli already covers interaction, nothing is blocked)."
  add_skip "mobile-mcp" "no claude CLI; mobilecli covers the interaction base"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Android: adb on PATH. On mac use the brew cask; on Linux point at putting
# platform-tools on PATH. Also probe ANDROID_HOME / ANDROID_SDK_ROOT to locate the SDK.
# ─────────────────────────────────────────────────────────────────────────────
section "Android (adb)"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -n "$ANDROID_SDK" ]; then
  log "ANDROID_HOME/SDK_ROOT = $ANDROID_SDK"
else
  log "Neither ANDROID_HOME nor ANDROID_SDK_ROOT is set (fine if adb is already on PATH)."
fi
if have adb; then
  ADB_VER="$(adb version 2>/dev/null | head -n1 || echo 'adb')"
  log "$ADB_VER"
  add_ok "adb" "$ADB_VER"
else
  log "adb not found, trying to install platform-tools…"
  if [ "$IS_MAC" -eq 1 ]; then
    if have brew; then
      if brew install --cask android-platform-tools >/dev/null 2>&1 && have adb; then
        ADB_VER="$(adb version 2>/dev/null | head -n1 || echo 'adb')"
        log "installed and verified: $ADB_VER"
        add_fix "adb" "installed via brew cask: $ADB_VER"
      else
        log "brew install failed. By hand: brew install --cask android-platform-tools"
        add_bad "adb" "brew install failed; run brew install --cask android-platform-tools"
      fi
    else
      log "no brew. Install Homebrew, then: brew install --cask android-platform-tools"
      log "  Or install Android Studio and put \$ANDROID_HOME/platform-tools on PATH."
      add_bad "adb" "no brew; install platform-tools and put it on PATH"
    fi
  elif [ "$IS_LINUX" -eq 1 ]; then
    # Nothing is force-installed on Linux (package managers differ per distro): prefer the platform-tools of an existing SDK
    if [ -n "$ANDROID_SDK" ] && [ -x "$ANDROID_SDK/platform-tools/adb" ]; then
      export PATH="$PATH:$ANDROID_SDK/platform-tools"
      if have adb; then
        ADB_VER="$(adb version 2>/dev/null | head -n1 || echo 'adb')"
        log "found adb in the SDK and added it to PATH for this run: $ADB_VER"
        log "  To make it permanent: add $ANDROID_SDK/platform-tools to your shell rc."
        add_fix "adb" "SDK platform-tools added to PATH: $ADB_VER"
      else
        add_bad "adb" "adb inside the SDK is not executable; check $ANDROID_SDK/platform-tools"
      fi
    else
      log "On Linux, install the Android SDK platform-tools and put them on PATH:"
      log "  Distro package (example — check the real package name): sudo apt install android-sdk-platform-tools"
      log "  Or download commandlinetools, install platform-tools, then:"
      log "    export PATH=\"\$PATH:\$ANDROID_HOME/platform-tools\""
      add_bad "adb" "install platform-tools and put them on PATH (see above)"
    fi
  else
    log "Not mac or Linux — installing adb automatically is unreliable here. Install platform-tools by hand and put them on PATH."
    add_bad "adb" "unknown platform; install platform-tools by hand"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# iOS (mac only; Linux and other platforms have no iOS toolchain and are skipped).
#   - Xcode CLT: xcode-select -p
#   - Simulator: xcrun simctl list devices booted
#   - Real device (optional): go-ios (which ios) + WDA (curl localhost:8100/status)
# ─────────────────────────────────────────────────────────────────────────────
section "iOS (mac only)"
if [ "$IS_MAC" -eq 1 ]; then
  # 1) Xcode Command Line Tools
  if XC_PATH="$(xcode-select -p 2>/dev/null)" && [ -n "$XC_PATH" ]; then
    log "Xcode CLT: $XC_PATH"
    add_ok "ios-xcode-clt" "$XC_PATH"
  else
    log "Xcode command line tools not found. Install (opens a GUI prompt, so it cannot be fully scripted):"
    log "  xcode-select --install"
    log "  Debugging on a real device also needs full Xcode plus accepting the license: sudo xcodebuild -license accept"
    add_bad "ios-xcode-clt" "run xcode-select --install"
  fi

  # 2) Simulator (an already-booted one wins)
  if have xcrun; then
    BOOTED="$(xcrun simctl list devices booted 2>/dev/null | grep -i 'Booted' || true)"
    if [ -n "$BOOTED" ]; then
      log "Booted simulators:"
      printf '%s\n' "$BOOTED" | sed 's/^/     /'
      add_ok "ios-simulator" "a booted simulator is available"
    else
      log "No simulator is booted right now. When you need one:"
      log "  xcrun simctl list devices            # see the available udids"
      log "  xcrun simctl boot <udid>             # boot one (non-destructive)"
      add_skip "ios-simulator" "none booted; simctl boot <udid> when needed"
    fi
  else
    log "no xcrun (Xcode CLT not fully installed), skipping the simulator check."
    add_skip "ios-simulator" "xcrun unavailable (install Xcode CLT first)"
  fi

  # 3) go-ios (needed for real devices, optional): which ios
  if have ios; then
    IOS_VER="$(ios --version 2>/dev/null | head -n1 || echo 'go-ios')"
    log "go-ios: $IOS_VER"
    add_ok "ios-go-ios" "$IOS_VER"
  else
    # Only needed for [real device + mobile-mcp] (mobilecli brings its own tunnel for real devices). Not installed proactively.
    log "go-ios not found (only needed for [real device + mobile-mcp]; neither simulators nor mobilecli on real devices need it). Install:"
    log "  npm i -g go-ios"
    add_skip "ios-go-ios" "missing (only for real device + mobile-mcp): npm i -g go-ios"
  fi

  # 4) WebDriverAgent (interaction backend for real devices, optional): localhost:8100/status
  if have curl; then
    if curl -s --max-time 2 http://localhost:8100/status >/dev/null 2>&1; then
      log "WebDriverAgent responds on localhost:8100"
      add_ok "ios-wda" "WDA :8100 ready"
    else
      log "WDA is not responding on :8100 (only needed for real-device interaction; simulators go through simctl)."
      log "  Real-device preparation is covered in references/ios.md (provisioning / trusting the device / starting WDA)."
      add_skip "ios-wda" "not running (real devices only); see references/ios.md"
    fi
  else
    add_skip "ios-wda" "no curl, skipping the WDA probe"
  fi
else
  log "Not on mac: the whole iOS toolchain (Xcode / simctl / WDA / go-ios) is skipped, only Android runs."
  add_skip "iOS" "not on mac, skipped entirely (Android only)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Optional accelerator: mobilewright doctor — a cross-platform checkup
# (Node/mobilecli/Xcode/Sim/Java/ADB). Failure is not fatal: it only cross-checks the
# results above and does not affect the exit code.
# ─────────────────────────────────────────────────────────────────────────────
section "mobilewright doctor (optional checkup)"
if have npx; then
  log "running npx mobilewright doctor --json (cross-platform cross-check, failure not fatal)…"
  if npx --yes mobilewright doctor --json >/dev/null 2>&1; then
    log "mobilewright doctor passed"
    add_ok "mobilewright-doctor" "checkup passed"
  else
    log "mobilewright doctor reported problems or is unavailable (not fatal; the per-item results above are authoritative)."
    log "  For details: npx --yes mobilewright doctor --json"
    add_skip "mobilewright-doctor" "warnings/unavailable (non-blocking; per-item results win)"
  fi
else
  log "no npx, skipping the mobilewright checkup."
  add_skip "mobilewright-doctor" "no npx, skipped"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Project-level Patrol configuration (only when inside a Flutter project: ./pubspec.yaml exists).
# Careful: pubspec is never modified — this only detects and prints the commands, leaving
# execution to you / the caller (a one-off, project-level investment).
# ─────────────────────────────────────────────────────────────────────────────
section "Project-level Patrol config (checked only inside a Flutter project)"
if [ -f "./pubspec.yaml" ]; then
  log "./pubspec.yaml detected, checking the Patrol project config (read-only, nothing is modified)…"
  MISSING=""

  # a) is patrol in dev_dependencies (loose match: pubspec contains a patrol dependency line)
  if grep -qE '^\s*patrol\s*:' "./pubspec.yaml"; then
    log "  ✓ pubspec contains a patrol dependency"
  else
    log "  ✗ no patrol dependency in pubspec. Add it: flutter pub add patrol --dev"
    MISSING="${MISSING} pub-add"
  fi

  # b) is there a patrol: config section (a top-level patrol: block holding app_name/android/ios)
  if grep -qE '^\s*patrol\s*:' "./pubspec.yaml" \
     && grep -qE '^\s*(app_name|android|ios)\s*:' "./pubspec.yaml"; then
    log "  ✓ a patrol: config section appears to exist (app_name/android/ios)"
  else
    log "  ✗ no patrol: config section. Add one at the top level of pubspec, e.g.:"
    log "      patrol:"
    log "        app_name: <your app name>"
    log "        android:"
    log "          package_name: <applicationId, read from build.gradle>"
    log "        ios:"
    log "          bundle_id: <bundleId, read from project.pbxproj>"
    MISSING="${MISSING} patrol-section"
  fi

  # c) the integration_test/ directory
  if [ -d "./integration_test" ]; then
    log "  ✓ integration_test/ directory exists"
  else
    log "  ✗ no integration_test/ directory. Create it and add <feature>_test.dart (see SKILL.md for how)."
    MISSING="${MISSING} integration_test-dir"
  fi

  if [ -z "$MISSING" ]; then
    add_ok "project-patrol" "pubspec / patrol section / integration_test all present"
  else
    log "  → project-level config is incomplete (careful: you or the caller runs this; the script does not touch pubspec):"
    log "      flutter pub add patrol --dev"
    log "      # then add the patrol: section (above) + integration_test/<feature>_test.dart"
    log "      # Android also needs the androidTest scaffolding: the patrol docs / references/android.md"
    add_bad "project-patrol" "missing$MISSING; follow the hints above (project-level, needs your confirmation)"
  fi
else
  log "No pubspec.yaml in the current directory, so this is not a Flutter project — skipping the project-level Patrol check."
  add_skip "project-patrol" "not inside a Flutter project (no pubspec.yaml), skipped"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary: ✓ ready / ⚙ fixed / ✗ needs a human / · skipped
# ─────────────────────────────────────────────────────────────────────────────
section "Summary"
# printf restores the \t/\n, then each line is formatted into an aligned, symbol-prefixed table
printf '%b' "$SUMMARY" | while IFS=$'\t' read -r st name desc; do
  [ -z "${st:-}" ] && continue
  case "$st" in
    OK)   printf '  %s✓ ready %s  %-22s %s\n' "$C_OK"  "$C_RST" "$name" "$desc" ;;
    FIX)  printf '  %s⚙ fixed %s  %-22s %s\n' "$C_FIX" "$C_RST" "$name" "$desc" ;;
    BAD)  printf '  %s✗ manual%s  %-22s %s\n' "$C_BAD" "$C_RST" "$name" "$desc" ;;
    SKIP) printf '  %s· skip  %s  %-22s %s\n' "$C_DIM" "$C_RST" "$name" "$desc" ;;
  esac
done

# Spell out what was skipped (platform-driven skips deserve naming, so they are not misread as "not installed")
if [ "$IS_LINUX" -eq 1 ] || { [ "$IS_MAC" -eq 0 ] && [ "$IS_LINUX" -eq 0 ]; }; then
  printf '\n%sNote: this machine is not a mac, so the entire iOS toolchain (Xcode/simctl/WDA/go-ios) was skipped — only the Android path is active.%s\n' "$C_DIM" "$C_RST"
fi

echo
if [ "$NEED_MANUAL" -eq 0 ]; then
  printf '%sEnvironment ready (everything ✓ or ⚙). You can enter the autonomous loop: dump ui → element-driven interaction / Patrol assertions.%s\n' "$C_OK" "$C_RST"
  exit 0
else
  printf '%sSome items need a human ("✗ manual", above). Fix them as described and just re-run this script (it is idempotent); everything already in place is skipped.%s\n' "$C_BAD" "$C_RST"
  printf '%sReminder: red-line operations (real money / keys and credentials / anything irreversible) are forbidden by default and allowed only with the user'"'"'s explicit prior authorization; a physically disconnected device stops the run only after one self-recovery attempt has also failed; every other reversible fix, just finish it.%s\n' "$C_DIM" "$C_RST"
  exit 1
fi

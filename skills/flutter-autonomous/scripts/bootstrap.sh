#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# flutter-autonomous · 环境自举(跨平台 mac/Linux,幂等可重入)
#
# 进自主模式第一件事:补齐工具链——能自己装/配的绝不停下要人工。
# 每项遵循:检测 → 缺则装 → 独立命令回验 → 已装跳过。可重复跑,不报错累积。
#
# 红线(脚本绝不碰;默认禁止,仅用户事先明确授权才可做):
#   ① 设备物理掉线/没插   ② 花真钱的操作(支付/扣费/转账/上链)
#   ③ 密钥/凭证操作(生产密钥/私钥/用户凭证) ④ 不可逆破坏(删数据/改生产)
# 本脚本只做可逆、低风险的本地安装与配置;不删数据、不改生产、不动设备资金。
#
# 退出码:0 = 全部就绪或已自动修复;非 0 = 有"需人工"项(见结尾汇总)。
# ─────────────────────────────────────────────────────────────────────────────
set -u   # 不开 -e:单项失败要记录后继续,而非整脚本中断

# ── 颜色(非 TTY 自动降级为空串,日志干净) ─────────────────────────────────
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_FIX=$'\033[33m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=''; C_FIX=''; C_BAD=''; C_DIM=''; C_RST=''
fi

# ── 平台判定 ────────────────────────────────────────────────────────────────
OS="$(uname -s)"   # Darwin = mac;Linux = Linux
case "$OS" in
  Darwin) IS_MAC=1; IS_LINUX=0 ;;
  Linux)  IS_MAC=0; IS_LINUX=1 ;;
  *)      IS_MAC=0; IS_LINUX=0 ;;   # 其他平台(MSYS 等)按非 mac 非 Linux 处理,iOS 跳过
esac

# ── 工具函数 ────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }   # 命令是否在 PATH

# 汇总收集:每项一行 "状态\t名称\t说明",结尾统一打印
SUMMARY=""
NEED_MANUAL=0                  # 任一项需人工 → 置 1 → 退出码非 0
add_ok()     { SUMMARY="${SUMMARY}OK\t$1\t$2\n"; }
add_fix()    { SUMMARY="${SUMMARY}FIX\t$1\t$2\n"; }
add_bad()    { SUMMARY="${SUMMARY}BAD\t$1\t$2\n"; NEED_MANUAL=1; }
add_skip()   { SUMMARY="${SUMMARY}SKIP\t$1\t$2\n"; }

# 分节标题
section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_RST"; }
# 过程日志(不进汇总)
log()  { printf '   %s\n' "$1"; }

# ── 确保 ~/.pub-cache/bin 在 PATH(patrol_cli / dart pub global 的可执行目录) ──
PUB_CACHE_BIN="${PUB_CACHE:-$HOME/.pub-cache}/bin"
ensure_pubcache_path() {
  case ":$PATH:" in
    *":$PUB_CACHE_BIN:"*) : ;;                       # 已在 PATH
    *) export PATH="$PATH:$PUB_CACHE_BIN" ;;          # 本进程内补上,子命令立即可用
  esac
}
ensure_pubcache_path

echo "${C_DIM}平台: $OS  |  pub-cache bin: $PUB_CACHE_BIN${C_RST}"

# ─────────────────────────────────────────────────────────────────────────────
# node(npx 依赖它;需 v22+)。缺只提示,不强装(版本管理器因人而异)。
# ─────────────────────────────────────────────────────────────────────────────
section "node"
if have node; then
  NODE_RAW="$(node -v 2>/dev/null || echo '?')"          # 形如 v22.3.0
  NODE_MAJOR="$(printf '%s' "$NODE_RAW" | sed -E 's/^v?([0-9]+).*/\1/')"
  if [ "${NODE_MAJOR:-0}" -ge 22 ] 2>/dev/null; then
    log "node $NODE_RAW (>= v22)"
    add_ok "node" "$NODE_RAW"
  else
    log "node $NODE_RAW 低于 v22 —— npx/mobilecli/mobile-mcp 可能不稳"
    log "  升级建议:fnm install 22 && fnm use 22   或   nvm install 22 && nvm use 22"
    add_bad "node" "当前 $NODE_RAW,需 v22+;用 fnm/nvm 升级"
  fi
else
  log "未找到 node。npx/mobilecli/mobile-mcp 都依赖它。"
  log "  安装建议(版本管理器,不强装):"
  log "    fnm:  curl -fsSL https://fnm.vercel.app/install | bash  &&  fnm install 22"
  log "    nvm:  https://github.com/nvm-sh/nvm  &&  nvm install 22"
  add_bad "node" "缺失;用 fnm/nvm 装 v22+"
fi

# ─────────────────────────────────────────────────────────────────────────────
# flutter SDK。缺只提示安装,不自动下 SDK(体积大、路径因人而异)。
# ─────────────────────────────────────────────────────────────────────────────
section "flutter"
if have flutter; then
  FLUTTER_VER="$(flutter --version 2>/dev/null | head -n1 || echo 'flutter (version 未知)')"
  log "$FLUTTER_VER"
  add_ok "flutter" "$FLUTTER_VER"
else
  log "未找到 flutter。请安装 Flutter SDK 并加入 PATH:"
  log "  https://docs.flutter.dev/get-started/install"
  log "  装好后 flutter doctor 自检;工具链约束(JDK/Xcode 版本)从项目 CLAUDE.md 读。"
  add_bad "flutter" "缺失;手动装 SDK(见 flutter.dev)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# mobilecli(交互底座:dump ui / io tap,免 MCP/重启)。
# 渠道一:npm 全局装。渠道二:GitHub Releases 下 Go 二进制。
# 企业 DLP 网关常拦 npm registry 而放行 GitHub —— 此时渠道二是唯一通路。
# 注意 npx 与 npm i -g 走同一个 registry,不构成回退,故不再作为兜底建议。
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# GitHub Releases 渠道(通用)——npm/brew 被企业网关拦时的备用路。
# 只针对【包管理源被拦】(现实里就是 npm 这类);Xcode/Android SDK/Google/Apple
# 的分发不在考虑范围——公司真拦那些,他们自己的开发也没法干活。
# 自动回退的:mobilecli、jq(上游 Releases 有预编译产物)。
# 救不了的:mobile-mcp、mobilewright(npm 包,release 无资产,clone 下来仍要
# npm install 拉依赖)、patrol_cli(发 pub.dev,是独立通道,npm 被拦不代表它被拦)。
# ─────────────────────────────────────────────────────────────────────────────
LOCAL_BIN="$HOME/.local/bin"

# 最新 tag:走 releases/latest 的重定向,不碰 API,不受未认证速率限制。
gh_latest_tag() {
  curl -sSLI -m 20 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$1/releases/latest" 2>/dev/null | sed 's#.*/tag/##'
}

# gh_asset_url <repo> <资产名关键字> → echo 下载地址;失败非 0。
# 一律【在真实资产列表里匹配】而不是拼文件名——上游改命名(加 v 前缀、
# 换 darwin/amd64 写法)也不会断。
gh_asset_url() {
  local repo="$1" pat="$2" tag name url
  tag="$(gh_latest_tag "$repo")"; [ -n "$tag" ] || return 1
  # ① expanded_assets 片段:不走 API、不受限流,返回的是真实资产名
  name="$(curl -sSL -m 20 "https://github.com/$repo/releases/expanded_assets/$tag" 2>/dev/null \
          | grep -oE 'href="[^"]*/download/[^"]*"' | sed 's#.*/##;s/"$//' \
          | grep -- "$pat" | head -1)"
  [ -n "$name" ] && { echo "https://github.com/$repo/releases/download/$tag/$name"; return 0; }
  # ② 退回 API(未认证有速率限制,超了返回 403)
  url="$(curl -sSL -m 20 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
         | grep -o '"browser_download_url": *"[^"]*'"$pat"'[^"]*"' | head -1 | cut -d'"' -f4)"
  [ -n "$url" ] && { echo "$url"; return 0; }
  return 1
}

# 装完统一修两处:zip 解出来没执行位;mac 上 curl 下来的都带 Gatekeeper 隔离属性。
fix_downloaded_bin() {
  chmod +x "$1" 2>/dev/null
  [ "$IS_MAC" -eq 1 ] && xattr -d com.apple.quarantine "$1" 2>/dev/null
  return 0
}

# gh_install <repo> <资产关键字> <落地命令名> [zip]
#   第 4 参给 "zip" 表示资产是压缩包(需解压后 find 出同名可执行);否则按裸二进制处理。
gh_install() {
  local repo="$1" pat="$2" bin="$3" kind="${4:-bare}" url tmp found
  have curl || { log "  无 curl,GitHub 渠道不可用"; return 1; }
  url="$(gh_asset_url "$repo" "$pat")" || { log "  未在 $repo 最新 release 找到含「$pat」的资产"; return 1; }
  log "  下载 $url"
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$LOCAL_BIN"
  if [ "$kind" = zip ]; then
    have unzip || { log "  无 unzip,无法解压"; rm -rf "$tmp"; return 1; }
    curl -sSL -m 180 -o "$tmp/a.zip" "$url" || { rm -rf "$tmp"; return 1; }
    unzip -oq "$tmp/a.zip" -d "$tmp/x"      || { rm -rf "$tmp"; return 1; }
    found="$(find "$tmp/x" -name "$bin" -type f 2>/dev/null | head -1)"
    [ -n "$found" ] || { log "  压缩包里没找到 $bin"; rm -rf "$tmp"; return 1; }
    cp "$found" "$LOCAL_BIN/$bin" || { rm -rf "$tmp"; return 1; }
  else
    curl -sSL -m 180 -o "$LOCAL_BIN/$bin" "$url" || { rm -rf "$tmp"; return 1; }
  fi
  rm -rf "$tmp"
  fix_downloaded_bin "$LOCAL_BIN/$bin"
  export PATH="$LOCAL_BIN:$PATH"            # 本进程内立即可用(注意:不跨 shell 留存)
  have "$bin"
}

# ~/.local/bin 可能已有产物但不在 PATH —— 先补进来,避免重复安装
case ":$PATH:" in *":$LOCAL_BIN:"*) : ;; *) [ -d "$LOCAL_BIN" ] && export PATH="$LOCAL_BIN:$PATH" ;; esac

# ─────────────────────────────────────────────────────────────────────────────
# jq —— scripts/tap-by-label.sh 硬依赖(缺了「按 label 一步点」就没法用)。
# 官方直接挂裸静态二进制,连解压都不用,是 brew 不可用时最容易补的一个。
# ─────────────────────────────────────────────────────────────────────────────
section "jq (tap-by-label.sh 依赖)"
if have jq; then
  log "$(jq --version 2>/dev/null || echo jq)"
  add_ok "jq" "$(jq --version 2>/dev/null || echo '已装')"
else
  JQ_DONE=0
  if [ "$IS_MAC" -eq 1 ] && have brew; then
    log "未找到 jq,渠道一:brew install jq…"
    brew install jq >/dev/null 2>&1 && have jq && JQ_DONE=1
  elif [ "$IS_LINUX" -eq 1 ] && have apt-get; then
    log "未找到 jq,渠道一:apt-get install jq…"
    sudo -n apt-get install -y jq >/dev/null 2>&1 && have jq && JQ_DONE=1
  fi
  if [ "$JQ_DONE" -eq 1 ]; then
    log "已安装并回验:$(jq --version 2>/dev/null)"
    add_fix "jq" "包管理器已装:$(jq --version 2>/dev/null)"
  else
    log "包管理器渠道不通,转渠道二:GitHub Releases(裸静态二进制)…"
    case "$(uname -s)/$(uname -m)" in
      Darwin/arm64)  JQ_PAT=macos-arm64 ;;
      Darwin/x86_64) JQ_PAT=macos-amd64 ;;
      Linux/aarch64) JQ_PAT=linux-arm64 ;;
      Linux/x86_64)  JQ_PAT=linux-amd64 ;;
      *)             JQ_PAT='' ;;
    esac
    if [ -n "$JQ_PAT" ] && gh_install jqlang/jq "$JQ_PAT" jq; then
      log "已从 GitHub Releases 安装并回验:$(jq --version 2>/dev/null)"
      add_fix "jq" "GitHub Releases 已装(在 $LOCAL_BIN)"
    else
      log "两条渠道都不通。tap-by-label.sh 将不可用(仍可手动 dump ui → io tap)。"
      log "  手挑产物:https://github.com/jqlang/jq/releases"
      add_bad "jq" "未装;tap-by-label.sh 不可用,见 references/restricted-network.md"
    fi
  fi
fi

section "mobilecli (交互底座)"
if have mobilecli; then
  MC_VER="$(mobilecli --version 2>/dev/null | head -n1 || echo 'mobilecli')"
  log "$MC_VER"
  add_ok "mobilecli" "$MC_VER"
else
  MC_DONE=0
  if have npm; then
    log "未找到 mobilecli,渠道一:npm 全局安装…"
    if npm i -g mobilecli@latest >/dev/null 2>&1 && have mobilecli; then
      MC_VER="$(mobilecli --version 2>/dev/null | head -n1 || echo 'mobilecli')"
      log "已安装并回验:$MC_VER"
      add_fix "mobilecli" "npm i -g 已装:$MC_VER"
      MC_DONE=1
    else
      log "npm 渠道不通(权限/网络/企业网关拦截)。转渠道二:GitHub Releases…"
    fi
  else
    log "无 npm。直接走渠道二:GitHub Releases…"
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
      log "已从 GitHub Releases 安装并回验:$MC_VER"
      log "  ⚠ 装在 $LOCAL_BIN,不在默认 PATH —— 后续每条命令前加:"
      log "      export PATH=\"$LOCAL_BIN:\$PATH\"; mobilecli ..."
      add_fix "mobilecli" "GitHub Releases 已装:$MC_VER(需 export PATH=$LOCAL_BIN)"
    else
      log "两条渠道都不通。手动排查:"
      log "  curl -sSL -m 10 -o /dev/null -w '%{http_code}\\n' https://github.com"
      log "  通 → 去 https://github.com/mobile-next/mobilecli/releases 手挑平台产物"
      log "  详见 references/restricted-network.md(备用渠道 / macOS 执行位与 quarantine)"
      add_bad "mobilecli" "npm 与 GitHub 渠道均不通;见 references/restricted-network.md"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# patrol_cli(Dart VM 按 Key 的可复跑断言)。缺 → dart pub global activate。
# ─────────────────────────────────────────────────────────────────────────────
section "patrol_cli (可复跑断言)"
if have patrol; then
  PATROL_VER="$(patrol --version 2>/dev/null | head -n1 || echo 'patrol')"
  log "$PATROL_VER"
  add_ok "patrol_cli" "$PATROL_VER"
else
  log "未找到 patrol,尝试 dart pub global activate…"
  if have dart; then
    if dart pub global activate patrol_cli >/dev/null 2>&1; then
      ensure_pubcache_path                          # activate 后产物落在 pub-cache/bin
      if have patrol; then
        PATROL_VER="$(patrol --version 2>/dev/null | head -n1 || echo 'patrol')"
        log "已安装并回验:$PATROL_VER"
        add_fix "patrol_cli" "dart pub global activate 已装:$PATROL_VER"
      else
        log "已 activate,但 patrol 仍不在 PATH。已临时 export:"
        log "  export PATH=\"\$PATH:$PUB_CACHE_BIN\""
        log "  永久生效请把上面这行加进你的 shell rc(~/.zshrc 或 ~/.bashrc)。"
        add_bad "patrol_cli" "已装但需把 $PUB_CACHE_BIN 加进 shell rc"
      fi
    else
      log "dart pub global activate patrol_cli 失败(网络?)。手动重试同命令。"
      add_bad "patrol_cli" "activate 失败;手动 dart pub global activate patrol_cli"
    fi
  else
    log "无 dart(随 Flutter SDK 提供)。先装好 flutter 再回跑本脚本。"
    add_bad "patrol_cli" "无 dart;先装 flutter SDK"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# mobile-mcp(MCP 版,可选)。注意:改 MCP 配置=下次会话才生效;
# 本会话仍用已装的 mobilecli 顶,别因 MCP 没连退回盲点坐标。
# ─────────────────────────────────────────────────────────────────────────────
section "mobile-mcp (MCP 版,可选)"
if have claude; then
  if claude mcp list 2>/dev/null | grep -qi mobile; then
    log "已注册 mobile-mcp(claude mcp list 命中 mobile)"
    add_ok "mobile-mcp" "已注册"
  else
    log "未注册 mobile-mcp,尝试 claude mcp add…"
    if claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest >/dev/null 2>&1 \
       && claude mcp list 2>/dev/null | grep -qi mobile; then
      log "已注册。注意:MCP 配置改动需下次会话才连上。"
      log "  本会话继续用 mobilecli(已装即用),别因 MCP 未连退回盲点 adb。"
      add_fix "mobile-mcp" "已 add,下次会话生效;本会话用 mobilecli 顶"
    else
      log "claude mcp add 失败。手动执行:"
      log "  claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest"
      log "  (失败不致命:mobilecli 已能覆盖交互底座)"
      add_bad "mobile-mcp" "mcp add 失败;手动 add(非阻塞,mobilecli 可顶)"
    fi
  fi
else
  log "无 claude CLI,跳过 MCP 注册(mobilecli 已覆盖交互,不影响推进)。"
  add_skip "mobile-mcp" "无 claude CLI;mobilecli 已顶替交互底座"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Android:adb 在 PATH。mac 用 brew cask;Linux 提示 platform-tools 入 PATH。
# 同时探测 ANDROID_HOME / ANDROID_SDK_ROOT 以便定位 SDK。
# ─────────────────────────────────────────────────────────────────────────────
section "Android (adb)"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -n "$ANDROID_SDK" ]; then
  log "ANDROID_HOME/SDK_ROOT = $ANDROID_SDK"
else
  log "未设置 ANDROID_HOME / ANDROID_SDK_ROOT(adb 若已在 PATH 也能用)。"
fi
if have adb; then
  ADB_VER="$(adb version 2>/dev/null | head -n1 || echo 'adb')"
  log "$ADB_VER"
  add_ok "adb" "$ADB_VER"
else
  log "未找到 adb,尝试安装 platform-tools…"
  if [ "$IS_MAC" -eq 1 ]; then
    if have brew; then
      if brew install --cask android-platform-tools >/dev/null 2>&1 && have adb; then
        ADB_VER="$(adb version 2>/dev/null | head -n1 || echo 'adb')"
        log "已安装并回验:$ADB_VER"
        add_fix "adb" "brew cask 已装:$ADB_VER"
      else
        log "brew 安装失败。手动:brew install --cask android-platform-tools"
        add_bad "adb" "brew 装失败;手动 brew install --cask android-platform-tools"
      fi
    else
      log "无 brew。装 Homebrew 后:brew install --cask android-platform-tools"
      log "  或装 Android Studio,把 \$ANDROID_HOME/platform-tools 加进 PATH。"
      add_bad "adb" "无 brew;装 platform-tools 并入 PATH"
    fi
  elif [ "$IS_LINUX" -eq 1 ]; then
    # Linux 不强装(发行版包管理器各异):优先用已有 SDK 的 platform-tools
    if [ -n "$ANDROID_SDK" ] && [ -x "$ANDROID_SDK/platform-tools/adb" ]; then
      export PATH="$PATH:$ANDROID_SDK/platform-tools"
      if have adb; then
        ADB_VER="$(adb version 2>/dev/null | head -n1 || echo 'adb')"
        log "从 SDK 找到 adb 并临时入 PATH:$ADB_VER"
        log "  永久生效:把 $ANDROID_SDK/platform-tools 加进 shell rc。"
        add_fix "adb" "SDK platform-tools 入 PATH:$ADB_VER"
      else
        add_bad "adb" "SDK 内 adb 不可执行;检查 $ANDROID_SDK/platform-tools"
      fi
    else
      log "Linux 请安装 Android SDK platform-tools 并加入 PATH:"
      log "  发行版包(示例,自行核对包名):sudo apt install android-sdk-platform-tools"
      log "  或下载 commandlinetools 装 platform-tools,再:"
      log "    export PATH=\"\$PATH:\$ANDROID_HOME/platform-tools\""
      add_bad "adb" "装 platform-tools 并入 PATH(见提示)"
    fi
  else
    log "非 mac/Linux 平台,自动装 adb 不可靠。手动装 platform-tools 入 PATH。"
    add_bad "adb" "未知平台;手动装 platform-tools"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# iOS(仅 mac 才跑;Linux/其他平台无 iOS 工具链,自动跳过)。
#   - Xcode CLT: xcode-select -p
#   - 模拟器:    xcrun simctl list devices booted
#   - 真机(可选):go-ios (which ios) + WDA (curl localhost:8100/status)
# ─────────────────────────────────────────────────────────────────────────────
section "iOS (仅 mac)"
if [ "$IS_MAC" -eq 1 ]; then
  # 1) Xcode Command Line Tools
  if XC_PATH="$(xcode-select -p 2>/dev/null)" && [ -n "$XC_PATH" ]; then
    log "Xcode CLT: $XC_PATH"
    add_ok "ios-xcode-clt" "$XC_PATH"
  else
    log "未找到 Xcode 命令行工具。安装(会弹 GUI,非脚本可全自动):"
    log "  xcode-select --install"
    log "  真机调试还需安装完整 Xcode 并接受协议:sudo xcodebuild -license accept"
    add_bad "ios-xcode-clt" "运行 xcode-select --install"
  fi

  # 2) 模拟器(已 boot 的优先)
  if have xcrun; then
    BOOTED="$(xcrun simctl list devices booted 2>/dev/null | grep -i 'Booted' || true)"
    if [ -n "$BOOTED" ]; then
      log "已启动的模拟器:"
      printf '%s\n' "$BOOTED" | sed 's/^/     /'
      add_ok "ios-simulator" "已有 booted 模拟器"
    else
      log "当前无已启动模拟器。需要时:"
      log "  xcrun simctl list devices            # 看可用 udid"
      log "  xcrun simctl boot <udid>             # 启动一台(非破坏)"
      add_skip "ios-simulator" "无 booted 模拟器;需要时 simctl boot <udid>"
    fi
  else
    log "无 xcrun(Xcode CLT 未装好),模拟器检查跳过。"
    add_skip "ios-simulator" "xcrun 不可用(先装 Xcode CLT)"
  fi

  # 3) go-ios(真机所需,可选):which ios
  if have ios; then
    IOS_VER="$(ios --version 2>/dev/null | head -n1 || echo 'go-ios')"
    log "go-ios: $IOS_VER"
    add_ok "ios-go-ios" "$IOS_VER"
  else
    # 仅「真机 + mobile-mcp」才需要(mobilecli 驱动真机自带隧道,不依赖它)。不主动装。
    log "未找到 go-ios(仅「真机 + mobile-mcp」需要;模拟器与 mobilecli 真机都不需要)。安装:"
    log "  npm i -g go-ios"
    add_skip "ios-go-ios" "缺(真机+mobile-mcp 才需):npm i -g go-ios"
  fi

  # 4) WebDriverAgent(真机交互后端,可选):localhost:8100/status
  if have curl; then
    if curl -s --max-time 2 http://localhost:8100/status >/dev/null 2>&1; then
      log "WebDriverAgent 在 localhost:8100 响应"
      add_ok "ios-wda" "WDA :8100 已就绪"
    else
      log "WDA 未在 :8100 响应(仅真机交互需要;模拟器走 simctl)。"
      log "  真机准备见 references/ios.md(provisioning / 设备信任 / 起 WDA)。"
      add_skip "ios-wda" "未运行(真机才需);见 references/ios.md"
    fi
  else
    add_skip "ios-wda" "无 curl,跳过 WDA 探测"
  fi
else
  log "非 mac 平台:iOS 工具链(Xcode / simctl / WDA / go-ios)整体跳过,只跑 Android。"
  add_skip "iOS" "非 mac,整体跳过(只跑 Android)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 可选加速:mobilewright doctor —— 跨平台体检(Node/mobilecli/Xcode/Sim/Java/ADB)。
# 失败不致命:仅作交叉印证,不影响退出码。
# ─────────────────────────────────────────────────────────────────────────────
section "mobilewright doctor (可选体检)"
if have npx; then
  log "运行 npx mobilewright doctor --json(跨平台交叉印证,失败不致命)…"
  if npx --yes mobilewright doctor --json >/dev/null 2>&1; then
    log "mobilewright doctor 通过"
    add_ok "mobilewright-doctor" "体检通过"
  else
    log "mobilewright doctor 报告了问题或不可用(不致命;以上逐项结果为准)。"
    log "  细看:npx --yes mobilewright doctor --json"
    add_skip "mobilewright-doctor" "有提示/不可用(非阻塞;以逐项为准)"
  fi
else
  log "无 npx,跳过 mobilewright 体检。"
  add_skip "mobilewright-doctor" "无 npx,跳过"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 项目级 Patrol 配置(仅当在 Flutter 项目内:存在 ./pubspec.yaml)。
# 谨慎:不强改 pubspec —— 只检测并给命令,由用户/上层执行(项目级一次性投入)。
# ─────────────────────────────────────────────────────────────────────────────
section "项目级 Patrol 配置 (在 Flutter 项目内才检)"
if [ -f "./pubspec.yaml" ]; then
  log "检测到 ./pubspec.yaml,核对 Patrol 项目配置(只读,不改动)…"
  MISSING=""

  # a) patrol 是否在 dev_dependencies(粗匹配:pubspec 含 patrol 依赖行)
  if grep -qE '^\s*patrol\s*:' "./pubspec.yaml"; then
    log "  ✓ pubspec 含 patrol 依赖项"
  else
    log "  ✗ pubspec 未见 patrol 依赖。补:flutter pub add patrol --dev"
    MISSING="${MISSING} pub-add"
  fi

  # b) 是否有 patrol: 配置段(顶层 patrol: 块,放 app_name/android/ios)
  if grep -qE '^\s*patrol\s*:' "./pubspec.yaml" \
     && grep -qE '^\s*(app_name|android|ios)\s*:' "./pubspec.yaml"; then
    log "  ✓ 疑似存在 patrol: 配置段(app_name/android/ios)"
  else
    log "  ✗ 未见 patrol: 配置段。在 pubspec 顶层补,例如:"
    log "      patrol:"
    log "        app_name: <你的应用名>"
    log "        android:"
    log "          package_name: <applicationId,从 build.gradle 读>"
    log "        ios:"
    log "          bundle_id: <bundleId,从 project.pbxproj 读>"
    MISSING="${MISSING} patrol-section"
  fi

  # c) integration_test/ 目录
  if [ -d "./integration_test" ]; then
    log "  ✓ 存在 integration_test/ 目录"
  else
    log "  ✗ 缺 integration_test/ 目录。创建并放 <feature>_test.dart(写法见 SKILL.md)。"
    MISSING="${MISSING} integration_test-dir"
  fi

  if [ -z "$MISSING" ]; then
    add_ok "project-patrol" "pubspec/patrol 段/integration_test 齐备"
  else
    log "  → 项目级配置需补(谨慎,由你/上层执行,本脚本不改 pubspec):"
    log "      flutter pub add patrol --dev"
    log "      # 然后补 patrol: 段(见上)+ integration_test/<feature>_test.dart"
    log "      # Android 还需 androidTest 脚手架:patrol 文档 / SKILL.md 的 references/android.md"
    add_bad "project-patrol" "缺$MISSING;按提示补(项目级,需你确认)"
  fi
else
  log "当前目录无 pubspec.yaml,不在 Flutter 项目内,跳过项目级 Patrol 检查。"
  add_skip "project-patrol" "不在 Flutter 项目内(无 pubspec.yaml),跳过"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 汇总:✓已就绪 / ⚙已修复 / ✗需人工 / ·跳过
# ─────────────────────────────────────────────────────────────────────────────
section "汇总"
# 用 printf 还原 \t/\n,再逐行格式化为带符号的对齐表
printf '%b' "$SUMMARY" | while IFS=$'\t' read -r st name desc; do
  [ -z "${st:-}" ] && continue
  case "$st" in
    OK)   printf '  %s✓ 已就绪%s  %-22s %s\n' "$C_OK"  "$C_RST" "$name" "$desc" ;;
    FIX)  printf '  %s⚙ 已修复%s  %-22s %s\n' "$C_FIX" "$C_RST" "$name" "$desc" ;;
    BAD)  printf '  %s✗ 需人工%s  %-22s %s\n' "$C_BAD" "$C_RST" "$name" "$desc" ;;
    SKIP) printf '  %s· 跳过  %s  %-22s %s\n' "$C_DIM" "$C_RST" "$name" "$desc" ;;
  esac
done

# 显式 echo 跳过了什么(平台相关跳过最值得点名,避免误判"没装")
if [ "$IS_LINUX" -eq 1 ] || { [ "$IS_MAC" -eq 0 ] && [ "$IS_LINUX" -eq 0 ]; }; then
  printf '\n%s说明:本机非 mac,已跳过全部 iOS 工具链(Xcode/simctl/WDA/go-ios),仅 Android 链路生效。%s\n' "$C_DIM" "$C_RST"
fi

echo
if [ "$NEED_MANUAL" -eq 0 ]; then
  printf '%s环境就绪(全部 ✓ 或 ⚙)。可进自主循环:dump ui → 元素驱动 / Patrol 断言。%s\n' "$C_OK" "$C_RST"
  exit 0
else
  printf '%s有"✗ 需人工"项(见上)。按提示补齐后重跑本脚本即可(幂等);已就绪项会自动跳过。%s\n' "$C_BAD" "$C_RST"
  printf '%s提醒:红线操作(花真钱/密钥凭证/不可逆)默认禁止、仅用户事先明确授权才可做;设备物理掉线自救一次仍败才停;其余可逆修复请直接做完。%s\n' "$C_DIM" "$C_RST"
  exit 1
fi

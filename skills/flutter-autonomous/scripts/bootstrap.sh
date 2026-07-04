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
# mobilecli(交互底座:dump ui / io tap,免 MCP/重启)。缺 → npm 全局装。
# ─────────────────────────────────────────────────────────────────────────────
section "mobilecli (交互底座)"
if have mobilecli; then
  MC_VER="$(mobilecli --version 2>/dev/null | head -n1 || echo 'mobilecli')"
  log "$MC_VER"
  add_ok "mobilecli" "$MC_VER"
else
  log "未找到 mobilecli,尝试 npm 全局安装…"
  if have npm; then
    if npm i -g mobilecli@latest >/dev/null 2>&1 && have mobilecli; then
      MC_VER="$(mobilecli --version 2>/dev/null | head -n1 || echo 'mobilecli')"
      log "已安装并回验:$MC_VER"
      add_fix "mobilecli" "npm i -g 已装:$MC_VER"
    else
      log "npm 全局安装失败(权限/网络?)。回退方案:"
      log "  临时用:  npx mobilecli@latest <子命令>"
      log "  或源码:  git clone 仓库 && make build,再把产物加入 PATH"
      add_bad "mobilecli" "npm 装失败;改用 npx mobilecli@latest 或源码 make build"
    fi
  else
    log "无 npm,无法自动装。回退:npx mobilecli@latest <子命令> 或源码 make build。"
    add_bad "mobilecli" "无 npm;用 npx 或源码安装"
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
    log "未找到 go-ios(仅真机调试需要;纯模拟器可忽略)。安装:"
    log "  npm i -g go-ios"
    add_skip "ios-go-ios" "缺(真机才需):npm i -g go-ios"
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

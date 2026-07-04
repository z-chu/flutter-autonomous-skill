# iOS 对等指南(模拟器优先 → WebDriverAgent 真机)

> 本文是 keystone（`../SKILL.md`）的 iOS 平台展开。术语、硬原则、闭环顺序、Key+Semantics 双标、验证四层、kill≠force-stop、自修复≤5 轮、commit 规范——**以 keystone 为准，本文不复述**，只补 iOS 落地差异。
> 占位符：`<udid>`（模拟器/真机的 UDID）、`<bundleId>`（应用包标识，从项目 `CLAUDE.md` 或 `ios/Runner.xcodeproj/project.pbxproj` 的 `PRODUCT_BUNDLE_IDENTIFIER` 读，**绝不写死**）、`<deviceId>`（mobilecli 视角的设备 id，模拟器即 UDID）、`<deeplink>`。
> **平台前提：iOS 工具链只在 macOS 上存在。Linux 跑这套自动化时只能跑 Android，iOS 部分整段跳过（见文末）。模拟器是 mac 专属。**

---

## 0. 两条线，模拟器优先

iOS 有两条互不相同的链路，**默认先用模拟器**：

| | 模拟器（Simulator） | 真机（Real Device） |
|---|---|---|
| 信任门槛 | **零**——`xcrun simctl` 直接驱动，无需签名/配对/信任 | 需要设备配对信任 + 开发者模式 + WDA 重签（provisioning profile） |
| CI 友好度 | 高，纯命令行可起可关 | 低，依赖物理设备 + USB + 证书 |
| 交互底座 | WDA（mobilecli/mobile-mcp 自动在模拟器内启 WDA） | WDA（经 USB 隧道 + 端口转发） |
| 用途 | **iOS 默认验证目标**：UI/导航/截图/Patrol 回归 | 只有真机才能验的：相机、真实推送、性能、特定硬件、生物识别 |

**结论：除非任务点名要真机能力，一律选模拟器。** 它零信任、可脚本化启停、CI 上能跑。真机是"必要时才付的额外成本"。

iOS vs Android 的对应关系（keystone 交互写法两端一致，差异只在底座命令）：

| 概念 | Android | iOS |
|---|---|---|
| 设备标识 | serial（`adb devices`） | UDID（`<udid>`） |
| 包标识 | applicationId（包名） | `<bundleId>` |
| 启动 | `am start` / adb | `xcrun simctl launch` 或 mobilecli |
| 关闭 | `am force-stop` | `xcrun simctl terminate` 或 `mobilecli apps terminate`（**不是** force-stop） |
| 日志 | `adb logcat -s flutter` | `xcrun simctl spawn <udid> log stream`（模拟器） |
| 硬键 BACK/DPAD | 有 | **无**（用手势 / 导航栏 tap） |
| 任意路径文件系统 | 有（`fs ls/push/pull`） | **无**（只 `apps path` 拿容器路径） |
| 清应用数据 | `apps clear` / `pm clear` | **不支持**（真机；模拟器需卸载重装或 erase） |

---

## 1. 模拟器链路（默认）

### 1.1 起停（两套等价，按手头工具选）

```bash
# 列出已安装的模拟器（含 UDID、状态）
xcrun simctl list devices            # 全部
xcrun simctl list devices booted     # 仅已启动（自举体检用这条）

# 启动 / 关闭一台模拟器
xcrun simctl boot <udid>             # 或 mobilecli device boot --device <udid>
xcrun simctl shutdown <udid>         # 或 mobilecli device shutdown --device <udid>
open -a Simulator                    # 可选：弹出模拟器窗口，便于肉眼旁观
```

mobilecli 的 `device boot/shutdown` 与 `simctl boot/shutdown` 等价——**有 mobilecli 就用 mobilecli，跨 iOS/Android 命令统一**；裸 `simctl` 作为底层兜底。`mobilecli devices` 会同时列出已启动的模拟器（`platform:ios, type:simulator, state:online`）。

### 1.2 装 / 起 / 关 App

```bash
# 安装（模拟器吃 .app 目录，或含 .app 的 .zip；mobilecli 自动解压 .zip）
xcrun simctl install <udid> /path/to/Runner.app
mobilecli apps install /path/to/build.zip --device <udid>   # .zip 含 .app

# 启动 / 终止
xcrun simctl launch    <udid> <bundleId>
xcrun simctl terminate <udid> <bundleId>
# 等价（推荐，跨端统一）：
mobilecli apps launch    <bundleId> --device <udid>
mobilecli apps terminate <bundleId> --device <udid>

# 深链跳关（省逐级导航，直达页面）
xcrun simctl openurl <udid> "<deeplink>"
mobilecli device url "<deeplink>" --device <udid>
```

> Flutter 通常直接 `flutter run -d <udid>` 自动构建+装+起；上面的 simctl 命令用于"已有产物想单独装/起/关"或收尾。

### 1.3 截图与日志

```bash
# 截图（落盘后 Read 核验）
xcrun simctl io <udid> screenshot /path/shot.png
mobilecli screenshot --device <udid> -o /path/shot.png      # 等价

# 日志流（验证四层里的"日志"层——连接/状态机/gating 最硬证据）
xcrun simctl spawn <udid> log stream --level debug --predicate 'processImagePath CONTAINS "Runner"'
# Flutter 的 print/debugPrint 也可走 `flutter logs`（跨端统一）
```

### 1.4 WDA 在模拟器上的自动起

模拟器的交互（tap/swipe/text/dump）都经 **WebDriverAgent**（监听 `localhost:8100`）。mobilecli `agent install` 会把 WDA 自动装到模拟器；mobile-mcp 走 `xcrun simctl launch <udid> com.facebook.WebDriverAgentRunner.xctrunner` 启 WDA，并轮询 `GET localhost:8100/status` 直到 `value.ready==true`。**模拟器无需 provisioning profile**（重签只在真机才需要）。

---

## 2. 真机链路（需信任 + 签名）

真机交互**全部经 WebDriverAgent**（`localhost:8100`）。mobilecli 会自动起 WDA + 端口转发 + USB 隧道；裸链路（mobile-mcp）需要 go-ios 自己搭隧道。

### 2.1 设备就绪四件事

1. **配对信任（usbmux）**：USB 连上后，设备首次会弹"信任此电脑"，点信任。
2. **开发者模式（iOS 16+）**：`Settings > Privacy & Security > Developer Mode` 打开并重启设备。否则装不上 WDA、起不来调试。
3. **隧道（iOS 17+）**：iOS 17 起需要隧道才能连 WDA。mobilecli 自动起；mobile-mcp 需 go-ios 起隧道，监听端口 **60105**。
4. **端口转发**：WDA 的 8100 转发到本机 `localhost:8100`。mobilecli 自动做；裸链路 go-ios 做。

### 2.2 mobilecli 真机：装 WDA（要 provisioning profile）

真机上的 WDA 必须用**有效的 Apple provisioning profile 重签**（模拟器不用）：

```bash
mobilecli agent status  --device <udid>           # 先查 WDA 是否已装
mobilecli agent install --device <udid> --provisioning-profile /path/to/x.mobileprovision
mobilecli agent install --device <udid> --provisioning-profile /path/to/x.mobileprovision --force   # 强制重装
```

**provisioning profile 捷径**：不必单独准备 WDA 专用描述文件。**app 自身的 `embedded.mobileprovision` 就能用**，mobilecli 会用它重签 WDA agent：

```bash
# Flutter 项目 debug 构建的 embedded.mobileprovision（构建过一次即可取到）
mobilecli agent install \
  --device <udid> \
  --provisioning-profile build/ios/Debug-iphoneos/Runner.app/embedded.mobileprovision
```

> 如果 debug 构建产物不存在，可先跑一次 `flutter build ios --debug`，或直接在 Xcode 里 Run 一次让 Xcode 完成签名；产物落到 `build/ios/Debug-iphoneos/Runner.app/` 后再装 agent。

装好后，`io tap` / `dump ui` / `screenshot` 等命令与模拟器**完全一致**，差异已被 mobilecli 抹平。

**⚠️ 真机截图速度**：iOS 真机经 WDA over USB 隧道截图每次约 **15–20 秒**（首次更长，含 WDA 冷启），属正常。建议减少截图频率——优先用 `dump ui` 判断页面状态，只在必要时（页面跳转验证、视觉布局核验）才截图。

### 2.3 mobile-mcp 真机：另需 go-ios + 隧道 + WDA

如果走 mobile-mcp（而非 mobilecli），真机额外需要：

```bash
npm i -g go-ios            # 提供 `ios` 命令；mobile-mcp 据此发现/驱动真机
ios list                   # 列出真机 UDID（go-ios 未装则发现不到任何物理设备）
ios info --udid <udid>     # 取 ProductVersion 等；iOS 17+ 判定需隧道
```

mobile-mcp 的就绪检查链（缺哪步报哪步，对照自查）：
- **隧道**：iOS 17+ 必须，监听 `localhost:60105`，不通 → 起隧道。
- **端口转发**：`localhost:8100` 不通 → WDA 端口未转发。
- **WDA 运行**：`GET localhost:8100/status` 不是 `ready:true` → WDA 没跑在设备上。

> `GO_IOS_PATH` 环境变量可指定 go-ios 二进制路径；不设则用 PATH 里的 `ios`。

---

## 3. 元素驱动交互：iOS 与 Android 同写法

keystone 的"检视优先 → 按 label 点 rect 中心"在 iOS 上**一字不改**：底座仍是 mobilecli `dump ui` → `io tap`，只是 iOS 经 WDA 取页面源。

```bash
D=<udid>                                               # 从 mobilecli devices 取，别写死
mobilecli apps launch     <bundleId> --device "$D"     # 拉前台
mobilecli apps foreground --device "$D"                # 确认前台=目标包（防串台）
mobilecli dump ui         --device "$D" > "$UI"        # 经 WDA 取元素：label/name + 屏幕坐标 rect（⚠️ 勿加 2>&1）
# 按 label 挑目标，点 rect 中心：
mobilecli io tap   --device "$D" <cx>,<cy>
mobilecli io swipe --device "$D" x1,y1,x2,y2
mobilecli io text  --device "$D" "文本"
mobilecli screenshot --device "$D" -o "$SHOT"          # → Read 核验
```

`scripts/tap-by-label.sh <deviceId> "<label子串>"`（keystone 提供）在 iOS 同样适用——内部 `dump ui` → jq 按 label 取 rect 中心 → `io tap`。

> **iOS stderr 日志**：iOS 真机经 WDA/USB 隧道运行时，`mobilecli` 会在 **stderr** 输出大量 `INFO connect to lockdown...` 日志。这些日志走 stderr、不走 stdout，所以 `dump ui > "$UI"` 能得到干净 JSON。**注意**：若写成 `dump ui > "$UI" 2>&1`（把 stderr 合并进文件），日志会污染 JSON 导致解析失败。加 `2>/dev/null` 可消除终端噪声，但不是必须。Android 无此问题。

### 3.1 WDA 元素过滤规则 → 为什么 Flutter 控件仍要暴露 Semantics

WDA 取设备无障碍树后，**只保留**满足以下两条的元素：
1. **类型在白名单内**：`TextField`、`Button`、`Switch`、`Icon`、`SearchField`、`StaticText`、`Image`。
2. **可见**（`isVisible==1` 且 rect 的 x/y ≥ 0）**且**至少有一个 `label` / `name` / `rawIdentifier`。

**含义（与 keystone 的 Key+Semantics 双标完全一致）**：Flutter 画在 canvas，控件不暴露 `Semantics` 时既没有 label/name 也不会被映射成 Button/TextField 等可识别类型 → **`dump ui` 列不出**。所以 iOS 端的铁律和 Android 一样：

- 标准 `Text`/`ElevatedButton`/`TextField` 自带可识别语义；
- **自定义手势控件（`GestureDetector`/`InkWell`/`Touchable`）必须显式包 `Semantics(label: ..., button: true)`**，否则 WDA 过滤后列不出；
- `dump ui` 列不出你的控件 = 没暴露 Semantics → **回代码补**，别降级盲点坐标。

> `Semantics(button: true)` 帮助控件被映射成 `Button` 类型（命中白名单），`label` 提供可读名字（命中"至少有 label/name"）——两者一起才稳定可点。

---

## 4. iOS vs Android 能力差异（避免用错命令）

| 能力 | iOS 真机/模拟器 | 替代做法 |
|---|---|---|
| 任意路径文件系统（`fs ls/push/pull/mkdir/rm`） | **不支持** | 只能 `mobilecli apps path <bundleId>` 拿容器路径；要读容器内文件走 Xcode/Devices 或模拟器 `~/Library/Developer/CoreSimulator/.../data` |
| 清应用数据（`apps clear`） | **不支持**（OpenRPC 明确：真机不支持；模拟器需卸载重装或 `xcrun simctl erase`） | 卸载重装：`apps uninstall` → `apps install`；或模拟器 `xcrun simctl erase <udid>` |
| 硬键 `BACK` / `DPAD_*` | **无**（这些是 Android only） | 用手势返回（屏幕左缘右滑）/ 点导航栏返回按钮（先 `dump ui` 找返回控件再 tap） |
| 硬键 `HOME` / `VOLUME_UP` / `VOLUME_DOWN` | 有（WDA 支持 home/volumeup/volumedown） | `mobilecli io button --device <udid> HOME` |
| `ENTER`（提交输入） | 经 WDA 发 `\n` | `io text` 里带换行，或 `io button ENTER` |
| 屏幕视频流 | **仅 mjpeg**（`screencapture --format mjpeg`；avc/H.264 是 Android only） | `mobilecli screencapture --device <udid> --format mjpeg \| ffplay -` |

口诀：**iOS 上别发 BACK/DPAD、别用 fs 任意路径、别 apps clear、screencapture 别要 avc**——这些一发就报错或无效，浪费一轮自修复。

---

## 5. Flutter 断言仍走 Patrol（不变）

keystone 的"可复跑 Flutter 断言用 Patrol（Dart VM 按 Key）"在 iOS **同样是唯一稳的确定性断言路径**，模拟器和真机都支持：

```bash
patrol test -t integration_test/<feature>_test.dart --device <udid> [--timeout 300]
```

Patrol 走 Dart VM 直连 widget 树按 `Key` 查找+断言，**不依赖 WDA 无障碍树暴露**——所以即使某控件没暴露 Semantics、`dump ui` 列不出，Patrol 仍能按 `Key` 命中。两条路各吃一样：`Key` 给 Patrol，`Semantics(label:)` 给元素驱动，**都加上**（见 keystone 代码契约）。

> **mobilewright 对 Flutter ⏳ 未正式支持**（与 keystone 工具决策树一致）。iOS 上的 Flutter 确定性回归断言**只用 Patrol**，别指望 mobilewright 的 `getByLabel().tap()` 命中 Flutter 控件。

---

## 6. 自举 iOS 检查项（缺则自己装/起，别停人工）

进自主模式先跑这几条体检；对应 keystone §0 的"检测→缺则装→独立命令回验"。**装工具/起模拟器/装 WDA 都是可逆低风险，自己做完接着干**——只有"真机物理掉线、花真钱的操作、密钥凭证操作、不可逆破坏"才停（keystone 四红线）。

| 检查 | 命令 | 期望 / 缺了怎么办 |
|---|---|---|
| Xcode CLT 在位 | `xcode-select -p` | 输出一个路径（如 `/Applications/Xcode.app/...` 或 `/Library/Developer/CommandLineTools`）；空/报错 → `xcode-select --install`（GUI 装则提示用户，CI 上预装） |
| 有已启动的模拟器 | `xcrun simctl list devices booted` | 列出至少一台 `(Booted)`；空 → `xcrun simctl list devices` 挑一台 → `xcrun simctl boot <udid>`（或 `mobilecli device boot`） |
| mobilecli 看得到设备 | `mobilecli devices` | 含 `platform:ios`；空且模拟器已 boot → 等几秒重试 |
| WDA 在跑 | `curl -s localhost:8100/status` | JSON 含 `"ready":true`；不通 → mobilecli `agent install --device <udid>`（真机加 `--provisioning-profile`，**直接用 app 自身的 `build/ios/Debug-iphoneos/Runner.app/embedded.mobileprovision` 即可，见 §2.2**），模拟器会自动起 WDA |
| 真机：go-ios 在位（仅走 mobile-mcp 真机时） | `which ios` && `ios version` | 有路径且版本以 `v` 开头；缺 → `npm i -g go-ios` |
| 真机：隧道（iOS 17+，走 mobile-mcp 时） | `curl -s localhost:60105` 或检查端口监听 | 端口在听；不通 → 用 go-ios 起隧道（mobilecli 自动起，无需手动） |

> 跨平台一把梭：`npx mobilewright doctor --json` 覆盖 Node/mobilecli/Xcode/Simulators/agent/Java/ADB（keystone §0 提及），再叠 `flutter doctor`、`patrol --version`。

---

## 7. 收尾清理（kill ≠ 关 App，iOS 版）

与 keystone 一致：`kill flutter run` 只断宿主进程，设备/模拟器上的 App 照跑。**iOS 用 terminate，不是 am force-stop**（force-stop 是 Android 概念，iOS 没有）。

```bash
kill "$(cat <PID_FILE>)" 2>/dev/null                       # 1) 停 flutter run 宿主
mobilecli apps terminate <bundleId> --device <udid>        # 2) 真关 App
#    等价：xcrun simctl terminate <udid> <bundleId>
# 3) 同设备别项目残留 App 也 terminate
mobilecli apps foreground --device <udid>                  # 4) 回查前台，确认不是残留 App
```

**宣布"测完/停好"前用独立命令回查真实状态**（`apps foreground` / `simctl list devices booted`），别拿"我执行了 terminate"当"App 关了"——这是 keystone 的"不验证不报完成"硬原则。

---

## 8. Linux / 平台边界（重要）

- **Linux 上没有 iOS 工具链**：没有 `xcrun`、没有 `simctl`、没有模拟器、go-ios 也无 macOS 私有框架支撑——本文整章在 Linux 上不可用。自动化在 Linux 环境**只跑 Android**（走 `references/android.md`），iOS 验证整段跳过，并在报告里注明"iOS skipped: not macOS"。
- **模拟器是 macOS 专属**：iOS Simulator 只能在 mac 上跑。真机调试也需要 mac（重签 WDA、Xcode 工具链）。
- 因此在 CI/无人值守里：mac runner 才跑 iOS（首选模拟器）；Linux runner 只承担 Android。环境探测先 `uname`/`xcode-select -p`，非 mac 直接走 Android 分支。

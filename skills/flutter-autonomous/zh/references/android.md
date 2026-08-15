# Android 平台细节（adb 是平台后端）

> 先读 keystone `SKILL.md`：交互底座统一 `mobilecli`，**有 `Semantics` 时一律走元素驱动**（`dump ui`→点 rect 中心），**adb 盲点是末选**——只有纯 canvas 无 Semantics 才回退量坐标。本文只写 Android 平台后端（adb）的深度细节，不复述方法论。
>
> 一句话定位：**Android 大多功能裸 `adb` 即可**（设备发现、前台核验、日志、收尾、像素）；`mobilecli` 在 Android 上正是用 `adb` 路径做发现与点击，**只有非 ASCII 输入才需要装 on-device agent**。占位符：`<id>`=设备序列号、`<applicationId>`=被测 App 包名（从项目 `CLAUDE.md` 或 `android/app/build.gradle(.kts)` 的 `applicationId` 读，绝不写死）。

---

## 1. adb 路径检测（找到可用的 adb 再往下）

按优先级探测，第一个命中就用，**绝不写死绝对路径**：

```bash
# 优先级：环境变量 > mac 默认 SDK > Linux 默认 SDK > 兜底裸 adb（在 PATH 里）
adb_bin() {
  if [ -n "$ANDROID_HOME" ] && [ -x "$ANDROID_HOME/platform-tools/adb" ]; then
    echo "$ANDROID_HOME/platform-tools/adb"
  elif [ -n "$ANDROID_SDK_ROOT" ] && [ -x "$ANDROID_SDK_ROOT/platform-tools/adb" ]; then
    echo "$ANDROID_SDK_ROOT/platform-tools/adb"
  elif [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]; then   # mac 默认 SDK 位置
    echo "$HOME/Library/Android/sdk/platform-tools/adb"
  elif [ -x "$HOME/Android/Sdk/platform-tools/adb" ]; then           # Linux 默认 SDK 位置
    echo "$HOME/Android/Sdk/platform-tools/adb"
  else
    command -v adb || { echo "adb 未找到，装 platform-tools 或设 ANDROID_HOME" >&2; return 1; }
  fi
}
ADB="$(adb_bin)"
```

- 两个环境变量都试：新工程多用 `ANDROID_HOME`，老工程可能只有 `ANDROID_SDK_ROOT`。
- 兜底裸 `adb`：用户可能用 Homebrew / 包管理器装的 platform-tools，已在 PATH。
- 真找不到属于**绿区**（keystone §2）——自己装 platform-tools 后回验 `"$ADB" --version`，别停下要人工。

---

## 2. 设备发现与一次性自救

```bash
"$ADB" devices            # 列出在线设备；每行 "<id>\tdevice" 才算就绪
```

判定与自救（**只自救一次**，对齐 keystone「物理掉线才停」红线）：

- 列表里有 `<id>\tdevice` → 就绪，往下走。
- **空 / 只有 header / 状态是 `offline` 或 `unauthorized`** → `"$ADB" kill-server && "$ADB" start-server` 自救一次，重列。
- 自救后仍空 = **物理掉线/没插/没授权调试**，这才是 keystone 红线①「设备物理掉线」，停下出卡住报告。
- `unauthorized`：设备上有「允许 USB 调试」弹窗没点 → 属物理侧人工，提示用户在设备上确认，别死等。
- 多设备并存：所有 adb 命令都带 `-s <id>` 锁定，`<id>` 运行期从 `"$ADB" devices` 现取，**绝不写进任何文件**。

> mobilecli 同样能列设备（`mobilecli devices`，输出 JSON 便于 `jq` 取 id），底层就是这条 adb 路径；二选一即可，脚本里取 id 用 mobilecli 的 JSON 更省解析。

---

## 3. 防串台：确认前台 = 被测 App

同一设备可共存多个 Flutter App（`applicationId` 不同、互不覆盖），截图/点击/读日志前**必须确认前台是目标包**，否则在别的 App 上点来点去还以为在测自己。

```bash
# 前台 Activity 所属包：输出里必须含目标 <applicationId>
"$ADB" -s <id> shell dumpsys activity activities | grep mResumedActivity
# 典型输出： mResumedActivity: ActivityRecord{... <applicationId>/.MainActivity ...}
```

- 不含目标包 = 串台了 → 先 `mobilecli apps foreground --device <id>` 或重新拉起目标 App，再继续。
- mobilecli 等价物：`mobilecli apps foreground --device <id>` 直接返回前台包名，比 grep dumpsys 更干净，优先用它。

**读日志先认目标 App 的 PID**——同设备所有 Flutter App 的 `I/flutter` 都进同一条 logcat，不按 PID 过滤会把别的 App 的日志当成自己的：

```bash
PID="$("$ADB" -s <id> shell pidof <applicationId>)"   # 空=App 没在跑
"$ADB" -s <id> logcat --pid="$PID"                    # 只看目标 App 的全部进程日志
```

---

## 4. 日志：抓连接 / 状态机 / 布局溢出（最硬的取证）

Flutter 的 `print`/`debugPrint` 走 `I/flutter` tag：

```bash
"$ADB" -s <id> logcat -s flutter            # 只看 Flutter 输出
"$ADB" -s <id> logcat -c                    # 跑用例前清旧日志，避免读到上轮残留
```

按 keystone「验证分层·⑦日志取证」grep 关键锚点（具体锚点串从项目 `CLAUDE.md` 读，下面是通用形态）：

```bash
# 连接类：WS/HTTP 连上的 URL、握手成功标志
"$ADB" -s <id> logcat -s flutter | grep -iE "ws://|wss://|connected|handshake"
# 状态机：状态名流转（确认走到了预期状态，比截图可靠）
"$ADB" -s <id> logcat -s flutter | grep -iE "state|status"
# 布局溢出：带文件:行号，直接定位到出问题的 widget
"$ADB" -s <id> logcat -s flutter | grep -iE "RenderFlex overflowed|overflowed by .* pixels"
```

- 长驻看日志另起后台 Bash 轮询，别阻塞主线程（参考 keystone 的 `until grep` 模式）。
- 连接/状态/gating 这类「发生了没发生」的判断**用日志，不用截图**——截图只证视觉/布局。

---

## 4.1 用「日志窗口」做断言（比全量 grep 硬）

全量 `logcat | grep` 的问题是分不清「这条日志是这一步产生的，还是上一步残留的」。**把日志切成以动作为单位的窗口**，断言才成立：

```bash
"$ADB" -s <id> logcat -c                                   # 1) 清缓冲，划定窗口起点
mobilecli io tap --device <id> <cx>,<cy>                   # 2) 执行【一个】动作
sleep 1
"$ADB" -s <id> logcat -d --pid="$PID" -s flutter > win.log # 3) 只取这一步的日志
grep -qE "<预期锚点>" win.log && echo PASS || echo FAIL     # 4) 对着窗口断言
```

- `-d` 是 dump 后退出（不是长驻），配合 `-c` 才能得到干净窗口。
- `--pid="$PID"` 防串台（§3），两者一起用。
- **App 侧配合打机器可读锚点**，断言就不用写正则去猜人类可读文本：

  ```dart
  dev.log('{"evt":"order_submitted","id":"$id"}', name: 'e2e');   // dart:developer
  ```

  断言侧 `grep -o '{.*}' win.log | jq -e 'select(.evt=="order_submitted")'`。锚点串本身放项目 `CLAUDE.md`。
- **更硬的错误断言**见 `vm-service.md` §4：`errorsSinceReload` 一次覆盖所有错误类型，不用为每种错误写一条 grep。

---

## 4.2 确定性开关：先关动画，再截图/点击

动画在跑时截图和点击都会飘，这是设备层 flake 的头号来源。**跑用例前关掉系统动画**（可逆，属绿区）：

```bash
for k in window_animation_scale transition_animation_scale animator_duration_scale; do
  "$ADB" -s <id> shell settings put global $k 0
done
```

**收尾必须还原并回查**（与 §10 断网同级——把用户设备留在「没有动画」的状态是收尾事故）：

```bash
"$ADB" -s <id> shell settings put global window_animation_scale 1.0
"$ADB" -s <id> shell settings put global transition_animation_scale 1.0
"$ADB" -s <id> shell settings delete global animator_duration_scale   # 该项默认可能是未设置
"$ADB" -s <id> shell settings get global window_animation_scale       # 回查：确认已还原
```

> **改设置前先读原值再改**，还原时写回读到的那个值，别假设默认是 1.0。实测有机型 `animator_duration_scale` 原本就是未设置（`null`），这种要用 `settings delete` 而不是写 1.0。

其它可控的确定性 / 场景开关（同样用完还原 + 回查）：

```bash
"$ADB" -s <id> shell settings put system font_scale 1.3           # 大字号下的布局核验
"$ADB" -s <id> shell cmd uimode night yes|no                      # 系统级深色模式
"$ADB" -s <id> shell pm grant|revoke <applicationId> <permission> # 权限流程的确定性前置
```

> 深色模式核验优先用 `vm-service.md` §3.5 的 `brightnessOverride`——**不改系统设置、不用还原**，比 `cmd uimode` 干净。

---

## 4.3 量化指标：启动耗时与掉帧（可断言的数字）

视觉和交互之外还有一个维度：**性能可以是验收标准的一部分**，而且是数字，不需要人来判断。

```bash
# 冷启动耗时：force-stop 后测，TotalTime 就是可断言的毫秒数
"$ADB" -s <id> shell am force-stop <applicationId>
"$ADB" -s <id> shell am start -W -n <applicationId>/.MainActivity | grep -E "TotalTime|LaunchState"
# → LaunchState: COLD / TotalTime: 1725

# 掉帧：跑完一段交互后读，给出 janky 比例与分位数
"$ADB" -s <id> shell dumpsys gfxinfo <applicationId> reset      # 先归零
# …执行要测的那段交互…
"$ADB" -s <id> shell dumpsys gfxinfo <applicationId> \
  | grep -E "Total frames|Janky frames|90th|95th|99th"
# → Janky frames: 1 (33.33%) / 90th percentile: 109ms
```

- `dumpsys gfxinfo` 的统计是**累积的**，不先 `reset` 读到的是开机以来的混合数据，断言无意义。
- 用法：把「首屏 TotalTime < X ms」「janky 比例 < Y%」写进验收标准，自主循环就能自己判过没过——比「感觉有点卡」可执行得多。阈值是项目特定值，放项目 `CLAUDE.md`。
- 更深的时间线用 `flutter run --profile --trace-to-file=<path>`（Perfetto proto 格式）。

---

## 5. 收尾：force-stop ≠ kill flutter run（必须回查）

`kill flutter run` 只断了宿主进程，设备上的 App 照常在跑（keystone 硬原则）。真关 App：

```bash
"$ADB" -s <id> shell am force-stop <applicationId>   # = mobilecli apps terminate --device <id> <applicationId>
"$ADB" -s <id> shell pidof <applicationId>           # 回查：输出为空 = 真关掉了
```

- `am force-stop` 与 `mobilecli apps terminate` 等价，mobilecli 已抹平平台差异，二选一。
- **回查铁律**：跑完 `force-stop` 后必须 `pidof` 确认为空，别拿「我执行了 force-stop」当「App 关了」（keystone「不验证不报完成」）。
- 同设备别的项目残留 App 也一并 `force-stop` + 回查前台，确认收尾后前台不是残留 App。

---

## 6. 物理像素（仅纯 canvas 无 Semantics 才用）

**有 Semantics 时不需要这一节**——`dump ui` 直接给设备像素 rect，取中心即点，无换算。只有纯 canvas 绘制（图表内部、无 Semantics 包裹的元素）两条路都找不到，才回退「截图肉眼量坐标 × 缩放比」。

```bash
"$ADB" -s <id> shell wm size      # 例：Physical size: <W>x<H> —— 设备真实像素，不是 dp
```

通用缩放公式（**不写具体数字**，运行期现算）：

```
缩放比 = 物理宽(wm size 的 W) / 截图宽(你 Read 的那张图的实际像素宽)
点击坐标(设备像素) = 你在截图上量到的坐标 × 缩放比
```

- 为什么要换算：`exec-out screencap` 出的图有时已是物理像素（缩放比=1），但经工具二次缩放/不同 DPI 截图工具后宽度会变，**必须用你手里这张图的实际宽去算**，别假设 1:1。
- 横向量到的 x 用「物理宽/截图宽」，纵向量到的 y 用「物理高/截图高」，等比时两者相同；保险起见分别算。
- 这是末选中的末选：能补 `Semantics(label:)` 让控件 dump 得出，就回代码补（keystone「列不出=代码缺陷修」），别长期靠量坐标。

---

## 7. 盲点末选命令（有 Semantics 一律走 mobilecli 元素驱动）

下面这些是**平台末选**，仅在纯 canvas、确实拿不到 Semantics rect 时用。优先级永远是 `mobilecli dump ui`→`io tap`（语义坐标）> 这些盲点 adb。

```bash
"$ADB" -s <id> shell input tap <x> <y>                  # 盲点（坐标须经 §6 换算）
"$ADB" -s <id> shell input swipe <x1> <y1> <x2> <y2> [<ms>]  # 滑动/滚动/下拉刷新
"$ADB" -s <id> shell input text "<ASCII文本>"           # 仅 ASCII；中文/emoji 喂不进（见 §8）
"$ADB" -s <id> shell input keyevent 4                   # 4 = BACK 返回
"$ADB" -s <id> exec-out screencap -p > shot.png         # 截图（exec-out 走二进制管道，不损坏 PNG）
```

- 截图务必用 `exec-out`（不是 `shell`），`shell screencap` 在某些机型会把 `\n` 转成 `\r\n` 损坏 PNG。
- `keyevent 4` 是 Android 专属的 BACK；mobilecli 的 `io button BACK` 已封装它，跨平台脚本用 mobilecli 那条（iOS 无 BACK）。
- `input text` 只能 ASCII，遇空格要转义或用 `%s`；非 ASCII 走 §8。
- 截图后必须 `Read` 那张图肉眼核验，别拿「截了图」当「看过了」。

---

## 8. mobilecli 在 Android 上的输入边界（非 ASCII 才需 agent）

- mobilecli 的 `io tap` / `io swipe` / `dump ui` / `screenshot` 在 Android 上都走 adb 路径，**零额外安装**。
- `io text` 输入**非 ASCII（中文/emoji）**时，adb `input text` 喂不进 → mobilecli 需要在设备上装一个 on-device input agent（IME）才能输。属「补工具」可逆操作：按 mobilecli 文档装好 agent 再继续，别停下要人工。
- 纯英文/数字输入裸 adb `input text` 就够，无需 agent。
- 注意区分：Flutter **自绘数字键盘 / 自定义手势控件**根本不是系统输入框，`io text` 和 adb `input text` 都喂不进 → 只能逐个 `io tap` 键的 rect 中心（keystone 已述）。

---

## 9. 工具链版本（项目特定，不放本文）

JDK / Gradle / Android SDK 版本是**项目特定**的，因机器/工程而异 → 放项目 `CLAUDE.md`，本文不写死。

- 仅提一句排错锚点：`flutter run` / Gradle 构建报 `compileDebugJavaWithJavac` 失败，**最常见是 JDK 版本与工程要求不匹配**（Gradle 用了系统默认 JDK 而非工程要求的版本）。具体该用哪个 JDK、怎么指定（`org.gradle.java.home` / `JAVA_HOME`）从项目 `CLAUDE.md` 读。
- 工具链报错属构建环境问题，按项目 `CLAUDE.md` 指定的版本修好再重跑，仍属**绿区**自己处理。

---

## 10. 断网/弱网测试（网络是系统状态：测完必须复原 + 回查）

验证离线降级 / 错误态 / 重连逻辑时，用 `svc` 切设备网络——**USB adb 不受影响**，断网期间元素驱动 / 截图 / 日志照常：

```bash
"$ADB" -s <id> shell "svc wifi disable; svc data disable"          # 断网
"$ADB" -s <id> shell "dumpsys connectivity | grep 'Active default'" # 回查：none = 已断
```

**恢复的坑：`svc wifi enable` 可能拉不起来**（三星真机实测踩到）：`settings get global wifi_on` 已是 1、`cmd wifi status` 却仍报 "Wifi is disabled"，反复 `svc` / `cmd wifi set-wifi-enabled` 循环都无效。**可靠恢复路径是 Settings UI**——Settings 是原生页、控件天生有无障碍标签，元素驱动一次到位：

```bash
"$ADB" -s <id> shell am start -a android.settings.WIFI_SETTINGS   # 打开 WLAN 设置页
mobilecli dump ui --device <id>                                    # 找 Wi-Fi 开关（label 如「切换」/「Off」）
mobilecli io tap --device <id> <开关rect中心>                       # 拨开关；~10s 内应关联上保存过的 AP
```

- **收尾铁律的网络版**：断过网就把「网络已恢复」纳入收尾回查——独立命令证明（`ping -c 1 8.8.8.8` 通、或 `dumpsys connectivity` 出现 Active default network），别拿「我执行了 enable」当「网络恢复了」。**把用户设备留在断网状态是收尾事故**，等级不低于没关 App。
- **`adb shell` 里的网络 ≠ App 的网络**：`adb shell curl/ping` 走的是设备**裸网络栈**，**绕开手机上 VPN/代理 App 建立的 TUN**。所以拿它判断「App 能不能连上某域名」，结论可以和 App 里看到的完全相反——设备挂着代理时，`adb shell` 里连不通、App 里通得好好的（反之亦然）。**判连通性以 App 自身的证据为准**：日志里的请求结果、VM Service 取到的状态；`adb shell` 只用来验证**物理链路**（有没有 Active default network）。判反一次的代价是去修一个根本不存在的网络 bug，或者把正常的网络报成「被限制」。
- 无 SIM 的测试机 Wi-Fi 是唯一通路（`getprop gsm.sim.state` 查），恢复失败没有移动数据兜底——更要回查到 ping 通为止。
- 测试设计提示：断网后**已加载进内存的数据不会消失**，要触发「空数据 + 加载失败」态通常得切到未加载过的资源（新 symbol / 新页面）再观察；离线冷启动则可能被更上游的错误墙挡住到不了目标页——切资源比冷启动更可控。

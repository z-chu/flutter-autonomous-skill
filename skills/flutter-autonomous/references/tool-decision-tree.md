# 工具选型:mobilecli / mobile-mcp / mobilewright / Patrol / adb·simctl 何时用

> 本文只讲**选型边界**——为什么有这几把工具、各自能做不能做什么、什么场景挑哪把。
> 方法论(元素驱动优先于盲点、Key+Semantics 双标、验证四层、收尾回查)在 `SKILL.md`,这里不复述。

---

## 一句话先记住

- **自主跑、即时交互/探索/诊断** → `mobilecli`(已装二进制,免 MCP/重启,这是默认手)。
- **想用 MCP 工具流(已注册)** → `mobile-mcp`(同引擎换皮,截图省 token,但改配置下次会话才生效)。
- **要可复跑的 Flutter 断言、进 CI** → `Patrol`(Dart VM 按 Key,iOS/Android 都稳——Flutter 唯一可靠确定性路径)。
- **要 TS 可复跑脚本 / 系统级 / 跨 app / 内嵌 webview** → `mobilewright`(Playwright 风,但 **Flutter ⏳ 未正式支持**)。
- **纯 canvas 盲点(无任何 Semantics)** → `adb`(Android)/ `simctl`·WDA(iOS),**末选**。

---

## ★ 同源同底座:三者都跑在 mobilecli 之上

mobilecli、mobile-mcp、mobilewright 都来自 **mobile-next**,共用同一套设备引擎:

```
                  ┌─ mobile-mcp     (MCP 协议封装,~23 个 mobile_ 工具)
mobilecli  ───────┼─ mobilewright   (Playwright 风 TS 框架,driver-mobilecli 走 WS JSON-RPC)
(设备引擎/CLI/HTTP·WS server)        其余直接用 mobilecli CLI 或 HTTP/WS API
```

含义:
- 三者**能力天花板一致**——底层都是同一引擎对接 iOS(WebDriverAgent / simctl / 真机 agent)与 Android(adb / UI Automator)。上层只是**交付形态**不同:CLI / MCP 工具 / TS locator。
- 选型本质是选**交付形态**,不是选"谁能做到":能用 mobilecli 一行命令搞定的,不必为它启 MCP 或写 TS。
- mobilecli 可作 server 跑(`mobilecli server start`,默认端口 12000,HTTP `/rpc` + WS `/ws`,JSON-RPC 2.0)。**推荐起 server 形态**:它能缓存、保活隧道,显著加快与设备/模拟器的反复交互。mobilewright 的 driver-mobilecli 就是连这个 WS。

---

## mobilecli —— 自主即时交互 / 探索 / 诊断的默认手

**为什么默认**:已装就是个二进制,**不依赖 MCP 注册、不需要重启会话**,装好立刻能用;坐标级 `dump ui` → `io tap` 闭环最短,适合"自己点、自己看、流畅推进"。

### 命令面速查表

| 域 | 命令 | 用途 |
|---|---|---|
| **devices** | `mobilecli devices` / `--include-offline` | 列在线设备(JSON);加 `--include-offline` 含未启的模拟器/模拟机 |
| **device** | `device boot` / `device shutdown` | 启动 / 关停模拟器·模拟机 |
| | `device reboot` | 重启设备 |
| | `device info` | 设备信息 |
| | `device orientation` | 读/设朝向 |
| | `device crashes list` / `crashes get <id>` | 列崩溃报告 / 取某条堆栈(iOS 真机走 crashreport service;模拟器读 DiagnosticReports;Android 解析 `logcat -b crash`) |
| | `device url <deeplink>` | 打开 deeplink / 自定义 scheme,**深链跳关**省逐级导航 |
| **apps** | `apps launch <bundleId>` | 拉起 App 到前台 |
| | `apps terminate <bundleId>` | 真关 App(Android=force-stop / iOS=simctl terminate,已抹平) |
| | `apps foreground` | **当前前台 App**(防串台校验:`packageName` 是否=目标包) |
| | `apps list` | 列已装 App |
| | `apps install <path>` / `apps uninstall <bundleId>` | 装(.apk/.ipa/.zip)/ 卸 |
| | `apps path <bundleId>` | App 数据容器路径(Android) |
| **io** | `io tap x,y` | 点坐标(取 `dump ui` rect 中心,不盲猜) |
| | `io longpress x,y [--duration ms]` | 长按 |
| | `io swipe x1,y1,x2,y2` | 滑动 / 列表滚动 / 下拉刷新 / 拖滑块 |
| | `io text '文本'` | 系统输入框输入(Flutter 自绘键盘喂不进,逐键 `io tap`) |
| | `io keys` | 发按键序列 |
| | `io button <HOME\|BACK\|POWER\|VOLUME_UP\|...>` | 硬件键(**BACK / DPAD 仅 Android**;iOS 无 BACK 用手势/导航栏 tap) |
| | `io gesture` | 自定义手势 |
| **dump ui** | `dump ui` | 列元素:label + **设备像素 rect{x,y,width,height}**;交互前先 dump 检视 |
| **screenshot** | `screenshot [-o file\|-]` / `--format jpeg --quality N` | 截图 → Read 核验;`-o -` 输出 stdout |
| **fs** | `fs ls / pull / push / mkdir [-p] / rm [-r]` | 设备/容器文件读写(**Android + iOS 模拟器**;`/data/user/` 需 app 可调试) |
| **webview** | `webview list / goto / reload / back / forward / url / title / content / query <css> / eval <js> / wait` | 内嵌 webview 检视与操作(**query/eval 仅作用 webview DOM,不作用原生/Flutter 控件**) |
| **agent** | `agent status / install [--force] [--provisioning-profile]` | 设备端 agent(**iOS 触控/截流/UI 树必需**;Android 仅非 ASCII 输入需要) |
| **server** | `server start [--listen :12000]` | 起 HTTP `/rpc` + WS `/ws`,缓存保活、加速反复交互 |
| **remote** | `remote allocate / list-devices / release` | 云端设备(device lab) |

> 几乎所有命令都吃 `--device <id>`;设备 id **运行期从 `mobilecli devices` 现取,绝不写进文件**。

---

## mobile-mcp —— 同引擎 MCP 化(可选;改配置下次会话才生效)

**是什么**:把同一套引擎封装成 MCP server,暴露 ~23 个 `mobile_` 工具(`mobile_list_elements_on_screen` / `mobile_click_on_screen_at_coordinates` / `mobile_launch_app` / `mobile_take_screenshot` / `mobile_swipe_on_screen` / `mobile_type_keys` / `mobile_press_button` / `mobile_open_url` / `mobile_list_crashes` / ...)。能力等价 mobilecli。

**什么时候用它而不是 mobilecli**:
- 想让交互走 MCP 工具流(被工具调用记录/复用、与其它 MCP 编排在一起)。
- 截图想省 token:`mobile_take_screenshot` **内置压缩**,比 mobilecli 原图省。

**注册**(Claude Code):
```bash
claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest
```
> ⚠️ **改 MCP 配置 = 下次会话才连**。本会话别因为"还没注册"就退回盲点 adb——先用 mobilecli 顶上,注册留给下次。

**坑与边界(相对 mobilecli 要补位)**:
- **无前台校验工具**:没有 `apps foreground` 等价物 → 防串台仍回退 `mobilecli apps foreground` 或 Android `dumpsys`。
- **无 fs 工具**:容器读写退回 mobilecli `fs` 或 adb。
- `mobile_open_url` 开**自定义 scheme** 需放开:`MOBILEMCP_ALLOW_UNSAFE_URLS=1`。
- **遥测默认开**(PostHog)→ 注册时带 `MOBILEMCP_DISABLE_TELEMETRY=1`:
  ```bash
  claude mcp add mobile-mcp -e MOBILEMCP_DISABLE_TELEMETRY=1 -e MOBILEMCP_ALLOW_UNSAFE_URLS=1 -- npx -y @mobilenext/mobile-mcp@latest
  ```

---

## mobilewright —— Playwright 风 TS 框架(Flutter ⏳ 未正式支持)

**是什么**:Playwright 开发体验搬到移动端,同样跑在 mobilecli 之上(`driver-mobilecli` 走 WS JSON-RPC)。卖点:
- **语义 locator + auto-wait**:`screen.getByLabel('Email').fill(...)` / `getByRole('button', {name:'Sign In'}).tap()` / `getByTestId(...)`,每个动作自动等元素可见·可用·bounds 稳定,**无需手写 sleep / 坐标**。
- **断言重试**:`expect(locator).toBeVisible()` 轮询到满足或超时。
- **reporter**(list/html/json/junit)+ **projects 多设备/多平台矩阵** + **retries** + **CI 友好**(`@mobilewright/test` 扩展 Playwright Test,fixture 化 `device`/`screen`,失败自动截图、可录像)。
- `npx mobilewright doctor [--json]` 是**现成跨平台体检**(Node / Xcode / Simulators / ADB / Java / mobilecli agent),环境自举可拿它当入口。

**★ 但对本 skill 的关键限制 —— Flutter ⏳ 未正式支持**:
- 框架支持表里 **Flutter 在 iOS / Android 双双标 ⏳**(注:Renders via Skia/Impeller, not native views — requires Dart VM Service driver)。Flutter 画 canvas、不出原生视图,mobilewright 的语义 locator 拿不到稳定的原生节点。
- 即便控件暴露了 Semantics,**Flutter 控件、尤其 iOS 上 `getByRole` 不可靠**(role 映射针对 UIKit/SwiftUI/RN 的原生类型,Flutter 对不上)。
- 结论:**Flutter 项目内部的 UI 断言不要押在 mobilewright 上**,那是 Patrol 的活。

**那 mobilewright 在本 skill 里干嘛用**:
- 写 **TS 可复跑脚本**(团队习惯 Playwright、要 reporter/CI 矩阵,且目标是**原生/RN/webview**而非 Flutter canvas)。
- **系统级 / 跨 app 流程**(出 Flutter App 去设置页、相册、另一个原生 App 走一段)。
- **内嵌 webview 内容**(webview 走原生无障碍树,locator 可用)。
- **`mobilewright doctor`** 作环境体检入口(这条与是否 Flutter 无关,随时能用)。

---

## Patrol —— Flutter 唯一可靠的确定性断言路径

**是什么**:Dart VM 直连 widget 树,按 `Key` 精确查找 + `expect` 断言,**iOS / Android 都稳、出 pass/fail、可复跑进 CI**。不依赖系统无障碍树是否暴露——这正是它对 Flutter 比 mobilewright/mobile-mcp 都可靠的根因(它在 Dart 侧看树,不在原生侧看 canvas)。

**什么时候必须是它**:
- 任何要**回归、要可复跑、要 pass/fail、要进 CI** 的 Flutter UI/集成断言。
- 元素驱动一次性点过了、但需要固化成长期回归用例时。

**和元素驱动的分工**(都在本 skill 内、互补):
- 探索期 / 一次性验证 → mobilecli `dump ui`→`io tap`(快,不留资产)。
- 固化期 / 回归 → Patrol 按 Key(慢一点,留下可复跑用例)。
- 故两者的代码契约一致:可交互/可断言控件**同时**加 `Key`(给 Patrol)+ `Semantics(label:)`(给元素驱动)。

> 命令与写法模板见 `SKILL.md`「自主开发完整循环」节,这里不复制。

---

## ★ 关键事实:没有"按 label 一步点"的原生命令

容易踩的误区:以为 mobilecli/mobile-mcp 能像 mobilewright 那样 `getByLabel('X').tap()` 一步到位。**不能**:

- **mobilecli / mobile-mcp 都是坐标级**:能力是「列元素(含 label + 像素 rect)」+「点坐标」两步,**没有按 label 直接点的原生命令**。
- mobilecli 的 `webview query` / mobile-mcp 没有的 `getBy*` —— 那些**只作用于 webview DOM**(CSS selector / JS),**不作用于原生控件,更不作用于 Flutter 的 Semantics 树**。
- 真正"locator 一步到位"的是 **mobilewright**,但它 **Flutter ⏳ 不支持**(见上)。

**所以在 Flutter 上"按 label 一步点"靠**:`scripts/tap-by-label.sh <deviceId> "<label子串>"`(零依赖 jq):内部 `dump ui` → jq 按 label 取 rect → 算中心 → `io tap`。这是把"列元素 + 点坐标"两步在脚本里粘成一步,补齐 mobilecli 缺的那条命令。

---

## 决策规则表(对着这张挑)

| 你要做的事 | 挑这把 | 因为 |
|---|---|---|
| 自主跑里**即时交互 / 探索 / 诊断**(点一下看效果、导航、抓崩溃、看前台) | **mobilecli** | 已装二进制,免 MCP/重启,闭环最短 |
| 想走 **MCP 工具流**(已注册 / 要截图省 token / 与别的 MCP 编排) | **mobile-mcp** | 同引擎换皮;但改配置下次会话才生效、无前台校验/无 fs |
| **Flutter 的可复跑 UI/集成断言**(回归、CI、要 pass/fail) | **Patrol** | Dart VM 按 Key,Flutter 唯一可靠确定性路径 |
| **TS 可复跑脚本 / 系统级 / 跨 app / 内嵌 webview**(且目标非 Flutter canvas) | **mobilewright** | Playwright 风 locator + auto-wait + reporter + CI;**Flutter ⏳ 不支持** |
| **环境体检** | **mobilewright doctor** | 现成跨平台,`--json` 可机读 |
| **按 label 一步点 Flutter 控件** | **`scripts/tap-by-label.sh`** | mobilecli/mobile-mcp 都无此原生命令;mobilewright Flutter 不支持 |
| **纯 canvas 盲点**(图表内部等无任何 Semantics) | **adb**(Android)/ **simctl·WDA**(iOS) | 末选;只要有 Semantics 一律走元素驱动 |

> 顺序心法:**能 mobilecli 就别起 MCP,能元素驱动就别盲点,要回归就上 Patrol,Flutter 断言永远不押 mobilewright。**

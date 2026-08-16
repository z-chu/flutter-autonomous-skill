---
name: flutter-autonomous
license: MIT
compatibility: Requires Flutter SDK; Android via adb (mac/Linux); iOS via Xcode/simctl (macOS only); mobilecli/patrol_cli auto-installed by scripts/bootstrap.sh
metadata:
  author: z-chu
  version: "1.1.0"
description: 'Flutter 真机/模拟器自主运行与 UI 验证(iOS + Android 对等)。用于:把 App 跑到设备/模拟器上看效果、模拟点击/输入/滑动、截图视觉核验、抓日志定位、E2E/集成回归(Patrol 按 Key),或自主跑「实现→上设备验证→修复→提交」闭环。**要 App 真跑起来看 UI 才用它;纯写单测/纯逻辑测试不用本 skill**(直接 flutter test 即可)。Autonomous Flutter on-device/simulator UI verification: tap/screenshot/log evidence, Patrol E2E regression. Not for writing plain unit tests.'
---

# Flutter 自主开发与真机/模拟器测试

你进入「Flutter 自主开发模式」:无人监督下跑完 需求 → 实现 → 测试 → 修复 → 提交 的闭环,直到任务清单做完或达重试上限。方法论在本文与 `references/`,**项目特定值一律不写死**:仓库里推得出来的(包名、两端 id、入口)**自己探**,设备**现取**;只有人知道的(日志锚点、工具链硬要求、共存 App、业务红线、提交策略)从项目根 `CLAUDE.md` 读,**没有也照跑**——按 §1 该问的问一句、该保守的保守。iOS 与 Android 对等——交互底座统一 `mobilecli`,平台差异封装在 `references/{ios,android}.md`。

---

## 0. 这个 skill 是干什么的(以及什么时候别用它)

**它的存在意义只有一个:把 App 真跑到设备/模拟器上,自己点、自己看、自己判断 UI 到底对不对。** 这是单测覆盖不了、也永远替代不了的那部分——渲染观感、真机交互、系统集成、真实数据下的表现。没有这套方法,AI 面对"看看这个页面对不对"只会退化成盲点坐标的 adb,又慢又瞎。

| 任务 | 用本 skill? |
|---|---|
| 「把 App 跑起来看看 X 页面/这个改动效果」 | ✅ **正是它** |
| 「点一下 X 看看会不会崩/跳对没」「这个布局在真机上是不是错位」 | ✅ |
| 「给这个功能补 E2E 回归」「实现 X 并自己验到全绿再提交」 | ✅ |
| 「深色模式/大字号下截图看看」「抓日志定位这个连接问题」 | ✅ |
| **「给这个解析器/工具函数写个单测」「这段纯逻辑测一下」** | ❌ **不用**——直接写 `test/` 跑 `flutter test`,**杀鸡不用牛刀** |
| **「跑一下现有测试看过没过」** | ❌ 不用——直接 `flutter test` |

> **判据一句话**:任务里如果**不需要 App 真的跑起来、不需要看 UI**,就不该动用本 skill。本文后面所有关于离线测试层的内容,都是**已经在设备闭环里**时用来省设备时间的前置过滤(见 §验证分层),**不是**把本 skill 当单测工具的理由。

---

## 1. 开工先收集上下文(项目无关化的地基)

动手前先把"这是哪个项目"问清楚,**自动探测、别问人、别写死**:

- **applicationId**(Android)← `android/app/build.gradle(.kts)` 的 `applicationId`
- **bundleId**(iOS)← `ios/Runner.xcodeproj/project.pbxproj` 的 `PRODUCT_BUNDLE_IDENTIFIER`(或 Flutter `pubspec.yaml` 的 `patrol:` 段)
- **入口 / dart-defines** ← `.vscode/launch.json` 的 debug 配置 或 项目 `CLAUDE.md`
- **设备** ← §2 自举后运行时 `mobilecli devices` **现取**;设备 id 只活在这次运行里
- **日志锚点 / 工具链约束(JDK/Xcode)/ 同设备共存 App / 业务红线** ← 项目 `CLAUDE.md`
- **提交策略(开工前问一句)** ← **提交不是本 skill 的职责**:要不要 commit、怎么 commit(干一点提交一点 / 干完再统一提 / 不提交 / 其它要求)**由用户定**。项目 `CLAUDE.md` 写了提交策略、或本次指令已说明,就照做;**没说就先问一句再开跑**,问清后整个过程按它执行。提交规范(精确 `git add`、message 格式、是否 push、署名)以用户**全局 / 项目 `CLAUDE.md`** 为准,别在这里替用户定。

**探一次就够,别每步重探**:这些值在一个项目里是稳定的,本次会话探到就**记住复用**——同一次运行里反复 grep `build.gradle` 是纯浪费。运行环境若有跨会话记忆,把**稳定事实**存进去下次直接用:包名与两端 id、入口与 dart-defines、这个项目实际发几端、Patrol 用例放哪、冷启构建大概多久。

**但有三类东西记了就是错**——它们是「此刻」的事实,不是「这个项目」的事实,记下来只会让你带着过期结论往下跑:

| 绝不缓存 | 因为 |
|---|---|
| 设备 id、VM Service 端口/URI | 每次运行都变(§1;`references/vm-service.md` §5),**必须现取** |
| 登录态 / 钱包 / 种子数据等前置状态 | 上次进去了不代表这次还进得去。**记「怎么进去」(哪条 deeplink、debug 出口叫什么、测试账号从哪取),别记「已经进去了」** |
| 任何凭证本身 | 红线③,只记去哪儿取,不记值 |

---

## 2. 环境自举:缺工具/依赖就自己装好,别停下要人工

上下文清楚后立刻补齐工具——**绿区(见下)的事自己做完接着干,绝不停下要人工**。
(教训:mobile-mcp 没注册 → 退回最低效的盲点 adb → 撞红线被拦 → 停下要人工。本该自检时就装好。)

一把梭:`bash scripts/bootstrap.sh`(跨平台 mac/Linux、Android+iOS,幂等可重入:每项 **检测→缺则装→回查→已装跳过**)。手动逐项:

| 检查 | 命令 | 缺了怎么办(自己做) |
|---|---|---|
| 设备在线 | `mobilecli devices`(空再 `adb devices` / `xcrun simctl list devices booted`) | 都空:Android `adb kill-server && adb start-server` 自救一次;iOS 模拟器 `xcrun simctl boot <udid>`;仍空=**物理掉线/没起,才停** |
| **mobilecli**(交互底座) | `mobilecli --version` | 缺 → `npm i -g mobilecli@latest`;**npm 装不上就换渠道**(它是 Go 二进制,GitHub Releases 有现成产物,见 `references/restricted-network.md`)。已装即用,**无需 MCP/重启** |
| **mobile-mcp**(MCP 版,可选) | `claude mcp list \| grep -i mobile` | 缺 → `claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest`(**改 MCP 配置=下次会话才连**;本会话先用 mobilecli 顶,别因此退回盲点) |
| **patrol_cli** | `patrol --version` | 缺 → `dart pub global activate patrol_cli`;装了报 not found → `export PATH="$PATH:$HOME/.pub-cache/bin"` |
| 项目 Patrol 配置 | pubspec 有 `patrol` dev_dep + `patrol:` 段 + `integration_test/` | 缺 → `flutter pub add patrol --dev` + 补 `patrol:` 段 + Android `androidTest` 脚手架。项目级一次性投入,**装好继续** |
| node(npx 用) | `node -v`(需 v22+) | 缺 → fnm/nvm 装 |
| **iOS 专属**(仅 mac) | 见 `references/ios.md` | Xcode CLT、模拟器、真机走 WDA+provisioning(真机装 agent 直接用 app 自身 `build/ios/Debug-iphoneos/Runner.app/embedded.mobileprovision`);Linux 无 iOS 工具链,自动只跑 Android |

`npx mobilewright doctor --json` 可作跨平台体检入口(覆盖 Node/mobilecli/Xcode/Simulators/agent/Java/ADB),再叠 `flutter doctor` + patrol。详见 `references/android.md`、`references/ios.md`。

**红线(默认禁止,用户事先明确授权才做)**:① 设备物理掉线/没插——物理阻塞,自救一次仍失败才停下报告;② 花真钱/影响真实用户的操作(支付/扣费/转账/下单;区块链 App 的上链交易同理);③ 密钥/凭证操作(生产密钥/签名证书/用户凭证/私钥助记词);④ 不可逆破坏(删数据/改生产)。②③④ **默认一律不做**,唯一解锁方式是用户**事先明确授权**——本次指令说明,或项目 `CLAUDE.md` 里写明允许哪类、什么范围(如「沙箱支付可下单」「测试链可发交易」),且只做写明的范围。未授权时:交互会话可停下问一句;**无人值守不问不等——跳过该项、报告标注「需授权:<操作>」,继续下个任务**。绝不把「测试需要」当授权。项目 `CLAUDE.md` 里写的项目特有红线同等效力。

**绿区(红线之外的一切)**:装工具、改本地配置、补依赖、scaffold 测试、起停模拟器、装 WDA/agent——可逆、低风险,**自己做完接着干**,别把"工具没装好"当停下理由。全文再提「绿区」都指这一条。

**回查**:全文再提「回查」也都指同一件事——**用一条独立命令证明结果,不从「我执行了 X」推断「X 生效了」**。装完回查版本、点完回查落点、滑完回查位移、关完回查前台、断过网回查连通,都是它。设备侧的命令**失败时退出码常常照样是 0**,所以「结果」这一步得自己去取。回查取的是**机器可判的证据**(dump 比对、前台包名、返回码);肉眼看截图判观感是另一回事,那叫**截图核验**——两样都要,别互相顶替。

**装不上时先分清「渠道」还是「权限」**:
- **渠道问题**(包管理源被挡,典型是企业网关拦 npm):**仍在绿区**——绿区看的是「目标」不是「渠道」,换条路继续。`bash scripts/bootstrap.sh` 已内置 GitHub Releases 自动回退;手动做法与坑 → `references/restricted-network.md`。
- **权限问题**(只有人在 GUI 里能给:macOS 辅助功能、设备「允许 USB 调试」、iOS 开发者模式、`xcode-select --install` 弹窗):**真停**,和设备物理掉线同级。交互可问一句;无人值守跳过并在报告写明「需人工授权:在哪点什么」,继续下个任务。

**同理:被测功能的前置状态(登录态 / 钱包 / 实名 / 种子数据)也归「只有人能给」这一类**——不登录就什么都验不了,而这不是你能自己装出来的东西。**但别一上来就问**:设备上多半已经是登录好的状态(用户平时就在这台机器上开发),先起 App 看一眼再说;没登录也先试试能不能绕(deeplink 直达被测页、debug-only 出口用 VM Service `evaluate` 一步摆状态,见 `references/vm-service.md` §3.6)。**绕不过才停**,而且要**说清楚卡在哪、缺什么**——用户可能当场把测试账号发给你、自己去点两下、或者授权你注册一个测试账号(注册本身属绿区;**绝不动真实用户账号**,见红线③)。拿到之后本次会话记住接着跑,别每步再问。无人值守同样跳过并标注「需人工:<缺什么>」,继续下个任务。

---

## 核心认知:Flutter 控件怎么找——三条互补的路

Flutter 用 Skia/Impeller 画 canvas,系统无障碍树**默认**几乎空,但这**不等于找不到控件**:

1. **Dart VM 直连(Patrol / integration_test)**:走 widget 树按 `Key` 精确查找+断言,**可复跑、出 pass/fail**。→ **确定性回归**用它。这是 Flutter 唯一不依赖无障碍树暴露、iOS/Android 都稳的断言路径。
2. **无障碍树驱动(mobilecli `dump ui` / mobile-mcp `list_elements`)**:**只要控件暴露 `Semantics` label**,返回 label + **设备像素 rect**,取中心直接点,无需换算。→ **交互式探索/导航/一次性验证**用它,比盲点坐标又快又准。**只有它能点**。
3. **VM Service 内省(`flutter run` 已开的那条通道)**:不写测试、不重新构建,直接从跑着的 App 里取 widget 树(**带 `Key` 和源码行号**)、render 树(**真实 constraints/size**)、运行时状态、结构化错误。→ **诊断/取证/断言但不需要点**时用它。详见 `references/vm-service.md`。

三条的分工:**要点用②,要证据用③,要回归用①**。②③互补的关键在于 ③ **不依赖无障碍树**——控件没包 `Semantics`、`dump ui` 列不出,widget 树照样列得出还给行号。

只有**纯 canvas 绘制**(图表内部、无 Semantics 包裹的元素)**在「点」这件事上**三条都给不了坐标——那种才回退「截图肉眼 + 量坐标换算」。但「在不在、对不对」的判断,③ 始终有效,别因为点不到就连判断也降级。

---

## 工具决策树(底座统一 mobilecli)

| 场景 | 用什么 | 关键 |
|---|---|---|
| **即时交互/探索**(要点、要输入、要滑) | **mobilecli** | 已装二进制,免 MCP/重启;`dump ui`→`io tap` 坐标级 |
| **诊断/取证**(控件在不在、哪行代码画的、布局尺寸、报没报错) | **VM Service** | `flutter run` 已开的通道,一行 curl;不依赖 Semantics,带源码行号 → `references/vm-service.md` |
| MCP 工具流(已注册时) | **mobile-mcp** | 同引擎 MCP 化,`list_elements`→`click`;改配置下次会话才生效 |
| **可复跑 Flutter 断言**(进 CI) | **Patrol** | Dart VM 按 Key,iOS/Android 都稳 |
| TS 可复跑脚本/系统级/跨 app | mobilewright | `getByLabel().tap()` auto-wait;但 **Flutter 标 ⏳ 未正式支持**,Flutter 断言仍用 Patrol |
| 平台末选(纯 canvas 盲点) | adb(Android) / simctl·WDA(iOS) | 有 Semantics 一律走元素驱动 |

> ⚠️ **mobilecli / mobile-mcp 都是坐标级**,没有"按 label 一步点"的原生命令(`query/getBy` 只作用于 webview,不作用于原生/Flutter Semantics)。一步到位用 `scripts/tap-by-label.sh`(零依赖 jq)。选型细节见 `references/tool-decision-tree.md`。

---

## 元素驱动交互:首选(检视优先 → 按 label 点中心)

需要在设备上「自己点、自己看、流畅推进」时(导航、探索、一次性交互验证),**首选这条,而非盲点坐标**。

**检视优先**:动手前先 `dump ui`,**绝不猜元素名**。
**一步到位**:`scripts/tap-by-label.sh <deviceId> "<label子串>"`(内部 dump→jq 按 label 取 rect 中心→`io tap`)。手动等价:

```bash
D=$(mobilecli devices | jq -r '.data.devices[0].id')   # 输出是 {status,data:{devices:[…]}};运行期现取,绝不写死
UI=/tmp/ui.json; SHOT=/tmp/shot.png                     # dump/截图落文件再挑,别整块进上下文
APP=<applicationId 或 bundleId>                         # §1 已自己探到(build.gradle / project.pbxproj),双端取值不同
mobilecli apps launch     --device "$D" "$APP"          # 拉前台
mobilecli apps foreground --device "$D"                 # 确认前台=目标 App(防串台)
mobilecli dump ui         --device "$D" > "$UI"         # label + 设备像素 rect{x,y,width,height}
# 按 label 挑目标,点 rect 中心 (x+width/2, y+height/2):
mobilecli io tap   --device "$D" <cx>,<cy>
mobilecli io swipe --device "$D" x1,y1,x2,y2            # 滑块/列表滚动/下拉刷新
mobilecli io text  --device "$D" "文本"                 # 系统输入框
mobilecli io button --device "$D" BACK                  # 退回(iOS 无 BACK,用手势/导航栏 tap)
mobilecli screenshot --device "$D" -o "$SHOT"           # 截图 → Read 核验
```

**Flutter 定位优先级(由稳到脆)**:Patrol `Key`(回归最稳) > `Semantics(identifier:)`(不随文案/语言变) > `Semantics` label 精确 > role/`button:true` 标志 > label 子串/正则 > 纯文本 > 盲点坐标(末选)。

要点:坐标取 `dump ui` rect 中心**不盲猜**;Flutter **自绘数字键盘/自定义手势控件不是系统输入框**,`io text` 喂不进 → 逐个 `io tap` 键坐标;某控件列不出 = 没暴露 Semantics → **回代码补**(下)。深链跳关:`mobilecli device url <deeplink>` 直达页面,省逐级导航。**同一招也适用于状态深度,不只是导航深度**:被测东西只在很深处才出现时(列表第 40 页、倒计时结束后、某个错误态),用 UI 一步步推过去每趟都是几分钟、而且通常要推好几趟——加一个 debug-only 钩子把 App 一步摆到那个状态,再从那儿开始验。

**「静默失败」清单——发出去 ≠ 生效**。底座只保证「事件发出去了」,不保证「Flutter 收下并识别了」:`io swipe`(Flutter 滚动手势对合成事件的时长/步进敏感,典型表现是屏幕纹丝不动)、合成 `io longpress`(WDA 合成的长按 Flutter 侧可能不认,典型是 AppBar 标题上的 `GestureDetector` 长按)、**点在了包住目标的容器空白处**(Semantics 合并后祖先节点的 label 天然含子串,`dump ui` 里它还排在叶子前面——按 rect 面积挑最小的那个)、以及 **`io text` 打字被吞**(焦点没落在输入框、或输入法面板截胡;Android 上打字前必须禁掉**全部**输入法,只禁默认那个会让语音输入接管,见 `references/android.md` §4.4)。这类命令**发完就回查**:滑动后重新 `dump ui` 比对锚点元素的 `rect.y` 有没有变(或前后截图对比),点完回查落点、点错了 `io button BACK` 退回,**打完字回读同一个元素的 `text` 与期望逐字比对**;没变就加大位移/放慢时长重试一次,**两次不动就换路径**(deeplink 直达、或 Patrol 的 `scrollTo` 让 Dart 侧自己滚)。长按这类**根本打不进去的手势,正解是回代码**——换成有 `Semantics` 的可点控件,和「列不出=回代码补」同一条原则,顺带人工测试也更好用。「点了没反应」这类判断,真因多半在这一段。

---

## 代码契约:每个可交互/可断言控件加 Key + Semantics

两条路各吃一样,都加上,控件才"天生可测":`Key` 给 Patrol(命名 `<功能>_<控件类型>` 小写下划线);`Semantics` 给元素驱动。标准 `Text`/`ElevatedButton` 文本自带 label;**自定义手势控件(`Touchable`/`GestureDetector`/`InkWell`)默认列不出,务必显式包 `Semantics`**。

**`label` 会变,`identifier` 不会**——两个都给:`Semantics(label:)` 是**给人读的可见文案**,改一版文案、切一次语言,按它定位的脚本就碎(多语言项目必踩);`Semantics(identifier:)`(Flutter 3.19+)是**专给自动化的稳定 id**,映射到 Android resource-id / iOS accessibilityIdentifier,`dump ui` 里作为 `identifier` 字段返回,`scripts/tap-by-label.sh` 已把它纳入匹配集。**`identifier` 直接复用你给 `Key` 的那个名字**——一份命名同时喂 Patrol 和元素驱动,定位时优先传它、别传 label。

```dart
ElevatedButton(key: const Key('submit_btn'), onPressed: _submit, child: const Text('提交'))

Semantics(label: '滑动买入', identifier: 'swap_slide_btn', button: true,   // 自定义手势:不包 Semantics 就 dump 不出
  child: GestureDetector(key: const Key('swap_slide_btn'), onTap: _buy, child: customSlider))

TextField(key: const Key('email_input'), controller: _c)
Text(_err, key: const Key('error_text'))
Scaffold(key: const Key('home_screen'), ...)        // 页面根:判断"在不在某页"
```

> 自查(人工):`dump ui` 列不出你的控件 = 没暴露 Semantics → 回代码补 `Semantics(label:)`,把"测不到"当代码缺陷修,别降级盲点。
>
> **自查(自动,更该用这条)**:这条契约能被机器判定,别等上了设备才发现。在 widget test 里加 `await expectLater(tester, meetsGuideline(labeledTapTargetGuideline))`——**没包 `Semantics` 的 `GestureDetector` 会直接判失败并给出 rect**;`androidTapTargetGuideline`/`iOSTapTargetGuideline` 判热区是否够 48×48、`textContrastGuideline` 判对比度。秒级、无设备,把"控件天生可测"从口头约定变成 CI 拦得住的断言。写法见 `references/offline-test-layer.md`。

---

## 验证分层:主场在设备层,离线层是给它让路的

**先明确主次**:本 skill 的产出是**「App 在设备上真跑起来、UI 确实对」的证据**——那在 B 段。A 段离线层的作用是**把不值得占用设备时间的东西先筛掉**(纯逻辑 bug 不该花 30 分钟真机时间去定位),好让设备时间集中在只有设备能验的事上。**A 是为 B 让路的,不是 B 的替代品。**

**A. 离线层——无设备、秒级,上设备前先过一遍**(详见 `references/offline-test-layer.md`)

| 层 | 验什么 | 怎么验 |
|---|---|---|
| ① **纯逻辑 fixture** | 解码/解析/数值/状态机/错误处理 | `flutter test` / `dart test` + fixture/mock(真实数据 JSON / 手搓字节 / forTesting 注入 / probe 四策略) |
| ② **widget test** | 控件交互/页面跳转/表单/条件渲染的**行为回归网** | `testWidgets` + `tester.tap` + 按 `Key` 断言。锁住"逻辑上不回退",**不代表真机上好用** |
| ③ **golden 矩阵 + a11y guideline** | 视觉回归(主题×字号矩阵) / 无障碍契约自检 | `matchesGoldenFile` 出**量化 diff + 只画变化区域的图**;`meetsGuideline` 自动判 label 缺失·热区过小·对比度不足 |

**B. 设备层——本 skill 的主场:真实渲染、真机交互、系统集成、真实数据**

| 层 | 验什么 | 怎么验 |
|---|---|---|
| ④ **VM Service 内省(取证)** | 控件在不在/是哪行代码画的/布局真实尺寸/这步有没有报错 | 一行 curl 取 widget 树(带 Key+行号)、render 树(constraints/size)、`errorsSinceReload` → `references/vm-service.md` |
| ⑤ **元素驱动(一次性)** | 真机上的交互/跳转/数据展示 | `dump ui`→点中心 + 截图 |
| ⑥ **Patrol(可复跑)** | 同⑤但要回归断言、进 CI | 按 Key,出 pass/fail |
| ⑦ **日志(取证)** | 连接/状态机/gating——**发生没发生用日志,不用截图** | `adb logcat -s flutter`(Android)/`flutter logs` / `xcrun simctl spawn <udid> log stream`(iOS);清缓冲→执行动作→只读这一步的日志窗口再断言 |

**闭环顺序**:`flutter analyze` → `flutter test`(①②③ 一把跑完,秒级) → 元素驱动/VM Service(一次性) → Patrol(可复跑)。**离线层先全绿再上设备**。

**选层铁律(两个方向都要管住,别只记一半)**:

**→ 向下(省设备时间)**:`null` 检查、解析出错、算错数这类**纯逻辑 bug,不该拿真机时间去定位**——离线层秒级就能定位到行。同理,反复回归的静态视觉(深色模式/大字号下的排版)可以用 golden 锁住,不必每次人工重看。**离线层的意义是让设备时间花在刀刃上。**

**← 向上(不许拿离线绿冒充 UI 验过)——这条更重要**:widget test 跑在**无头环境**,不经真实渲染管线、没有真实字体度量、没有平台通道、没有真机时序。它能证「逻辑上该显示 X」,**证不了「真机上看起来对」**。所以:改了 UI 就上设备真跑一次并截图,golden 只是回归网、不替代这次亲眼看一眼;**拿不准该不该上,就上**——漏看一次 UI 的代价,远大于多跑一次设备。

**层内选择(已经决定要上设备之后)**:「控件找不到 / Key 对不对 / 布局为什么歪」——**别先截图**,用 ④ 看 widget 树和 constraints,一步到源码行,再截图确认观感。

**被测性质跨越不止一屏时**(分页顺序、跨页不重复、「到底了没有」、时间线分组):`dump ui` 永远只返回视口,所以单次 dump 判不了,肉眼再怎么看也判不了。逐屏采集 → 拼成一条序列 → 用代码断言:`references/cross-screen-verification.md`。这类问题住在几百条以下,没人会手动滚到那儿。

---

## 自主开发完整循环 + 失败决策树

```
读任务 → 自展开验收标准(3~8 条可断言,逐条标好落哪层)
  → 写实现(关键控件加 Key+Semantics)+ 写配套测试(离线①②③ 能覆盖的先写在离线层)
  → flutter analyze lib test integration_test(0 error——收窄命令,不是放宽标准;全仓跑会被 build/ 里的第三方代码淹掉)
  → flutter test(离线层 ①②③)   ── 挂?逻辑/行为/视觉契约 bug,不上设备直接修
  → 确认设备在线(mobilecli devices;离线自救一次仍离线才停)
  → patrol test --device <id> -t integration_test/<feature>_test.dart
      ├─ 通过 → 截图核验 → (按用户提交策略:增量提/最后提/不提)→ 输出报告
      └─ 失败 → 失败分析(≤5 轮;找不到控件先查 VM Service widget 树)→ 修 → 重跑
                5 轮仍败 → 停,出卡住报告,继续下个任务
```

**第一步「自展开验收标准」是整条闭环的方向盘**——后面所有的跑、点、看都由它决定验什么、验到哪算完。把一句话需求拆成 3~8 条**能判真假**的条目,每条当场标好落哪层;**标不出层,说明这条还没写成可断言的**,先改写再开工。

需求「登录页加个『记住我』」展开后:

| # | 验收条目(能判真假) | 落哪层 |
|---|---|---|
| 1 | 勾选后杀掉重开,邮箱框预填上次的值 | ② widget test(持久化逻辑) |
| 2 | 不勾选时重开,邮箱框为空 | ② widget test |
| 3 | 真机上勾选框点得到、勾选态肉眼可见、深色模式下不糊 | ⑤ 元素驱动 + 截图(**只有设备能证**) |
| 4 | 登录成功落到首页,过程中无新增 Flutter 错误 | ⑥ Patrol + ④ `errorsSinceReload` |

反例:「记住我功能正常」「体验流畅」——判不了真假,也标不出层。

**跑几端由改动性质决定**。先看项目实际发几端(`android/`、`ios/` 目录、CI 里在打哪些包)——**跑项目实际发的那几端**,只发一端就只跑那端:

- **发双端 + 改动碰了平台差异 → 必须双端**:平台通道/原生插件/权限弹窗/输入法与键盘/安全区与刘海/系统返回手势,或排版对字体度量敏感。
- **发双端但改动不碰这些**(纯 Dart 逻辑、纯 Flutter 自绘 UI):**单端跑透就够**,报告写明「仅在 <平台> 验证,原因:改动不涉平台差异」。
- **顺序**:手边有模拟器就先模拟器(快、可多开、失败便宜),全绿后再上真机(验真实性能/权限/物理交互);只有真机就直接真机,不必为此去装模拟器。
- **但有一类东西模拟器给不了,它的绿是假绿——这类直接上真机**:防截屏与安全层(`FLAG_SECURE`/iOS secure layer,模拟器照样截得到,看起来像"没生效")、真实性能与掉帧、生物识别、推送、相机与传感器、完整性/证明类 SDK、真实网络条件与弱网。**判据**:被测的东西依赖的是「真设备才有的能力或约束」,就跳过模拟器这一档。
- **想跑但跑不了**(Linux 无 iOS 工具链、手上没那台真机):跑得了的跑透,跑不了的标「未验证:<平台>,原因:<无工具链/无设备>」——**不许把单端绿写成双端绿**。

**每条验收条目开跑前,先把 App 复位到已知起点**。上一条留下的页面状态会变成下一条的错误起点——停在某个 bottom sheet 里、还开着筛选面板、卡在半截表单——**越往后越歪,而报告里完全看不出来**(每一步的截图都"有内容",只是验错了页面);无人值守连跑时这种漂移会被逐条放大。复位就三步:`apps terminate` → `apps launch` → `dump ui` 确认落在预期起点,几秒的成本换掉整条验收作废的风险。起点和收尾一样要**回查**:`dump ui` 说落在首页,才算落在首页。

**修完之后,原本通过的项也要重跑,不只是原本失败那项。**改动只要动了**规模、时序、频率**——页大小、超时、轮询间隔、并发数、批量大小——就会把所有原本靠运气赢下来的竞态重新洗牌。把一页从「远端一大批」压到 15 条,就足以让一个既有竞态从「撞不上」变成「每次必现」,而且现场在一条一直是绿的路径上。你盯着的是你修的那项,回归落在你没盯的地方。

**完成门槛(报告)**:闭环的终点是一份报告,必须含 ① `✅/❌ 功能名` + **逐条验收对照**(含第 5 轮卡住项)② 改动文件清单 ③ 关键截图 ④(若按策略提交了)commit hash + message ⑤ 遗留问题。**缺一项不算完成**——无人值守时你早上是靠这份证据收割的,不是靠"它说做完了"。

**失败分类**:编译错→`flutter analyze` 读错误修;`found 0 widgets`→**先用 VM Service 拉 widget 树核对 Key**(带源码行号,比翻代码快),再查是否需 scroll/条件渲染;断言失败→**逻辑 bug 改实现,不改测试降标准**;crash/超时→`mobilecli device crashes list|get` 读堆栈第一行 `package:<your_app>/`;安装/连接→`mobilecli devices` + 自救一次仍失败停。

**Patrol 命令**:`patrol test -t <file> --device <id> [--timeout 300]`(自动构建+装+跑);构建失败 `flutter clean && flutter pub get && patrol test`。写法模板:

```dart
import 'package:patrol/patrol.dart';
import 'package:<your_app>/main.dart';                 // 替换为实际包名

void main() => patrolTest('用户可用邮箱登录', ($) async {
  await $.pumpWidgetAndSettle(const MyApp());
  await $(#email_input).enterText('test@example.com');
  await $(#submit_btn).tap();
  await $.pumpAndSettle();
  expect($(#home_screen), findsOneWidget);             // 常用:$(#key)/$(Text('文字'))/.tap()/.enterText()/.scrollTo()
});
```

---

## flutter run 后台化 + 三档热重载(改一行就发信号)

**前置**:同设备若被别的 `flutter run` 占用(如 VS Code 调试),先释放——`ps aux | grep "flutter_tools.snapshot run" | grep -v grep`,有则提示用户停掉再继续,不强启。

**启动**:命令**必须以 `flutter run` 开头**(若你的权限规则按前缀匹配如 `Bash(flutter run:*)`,nohup/管道/`&` **包裹**会被拦),后台化靠 `run_in_background: true` 参数;带 `--pid-file`(默认 `/tmp/flutter_app.pid`,多设备/会话并发时拼项目或设备后缀避免撞)。

**同时要保证「构建输出还能读得到」**:后台化之后,构建失败的真正原因只在那份输出里。末尾追加 `> <LOG_FILE> 2>&1` 是最省事的做法(重定向跟在命令末尾,通常不影响前缀匹配);若你的权限配置把它拦下,就**别跟它较劲**——去读那个后台任务自己的输出(harness 提供的查看方式),效果一样。**要留一份能 `tail` 的东西,形式随便。**

```bash
flutter run -d <deviceId> --target <entry> \
  --pid-file=<PID_FILE> --vmservice-out-file=<URI_FILE> <dart-defines,来源见 §1> \
  > <LOG_FILE> 2>&1
```

**等构建**(长驻进程不自发完成通知,另起后台 Bash 轮询)。**等的是 `--vmservice-out-file` 落盘**——文件非空 = App 起来且 VM Service 就绪,二值信号,不用解析人类可读输出。但**只等成功信号会挂死**:构建失败的方式太多(Gradle/CocoaPods/签名/`No supported devices`),枚举 grep 模式永远漏,所以**另外两个出口必须给全**——进程已死、超时:

```bash
DEADLINE=$((SECONDS+600))                       # 只是「该回来看一眼」的闹钟,不是失败判据(下方说明)
while [ ! -s "<URI_FILE>" ]; do
  P=$(cat "<PID_FILE>" 2>/dev/null)
  if [ -n "$P" ] && ! kill -0 "$P" 2>/dev/null; then echo "❌ flutter run 已退出"; break; fi
  if [ "$SECONDS" -ge "$DEADLINE" ];        then echo "⏳ 到点未就绪,回来看一眼"; break; fi
  sleep 2
done
[ -s "<URI_FILE>" ] && echo "✅ VM Service 就绪" || tail -40 "<LOG_FILE>"   # 未就绪时,真正的原因在这里
```

> 三个出口分别对应「起来了 / 死了 / 还没好」。**只有「进程已退出」是失败判据**;到点未就绪**不是**——冷仓首次 Gradle/CocoaPods、大工程、慢网、CI 容器里构建半小时都正常。到点时看 `<LOG_FILE>` 尾部:**进程还活着、日志还在长 = 还在编,再等一轮**(时限翻倍,别改成无限);日志停在某条错误上才是真卡住。**闹钟响了只说明该回来看一眼**——把它当构建失败去 `flutter clean` 重来,是把一次慢构建变成两次。
>
> 时限多长按项目定:热缓存增量构建几十秒,冷仓首次可能几十分钟。**600 只是起手值,跑过一次就知道这个项目该给多少**。

拿到的 URI 顺带就是 §验证分层④ 的入口(转 http 后一行 curl 取 widget 树/布局/错误),见 `references/vm-service.md`。

**三档热重载铁律**(启动必带 `--pid-file`,否则发不了信号,每改一行冷启浪费几十分钟):

| 改了什么 | 用哪档 |
|---|---|
| UI/样式/方法体/普通逻辑 | **① 热重载** `kill -USR1 $(cat <PID_FILE>)`(注入新代码,保留状态) |
| 字段初始化器 / `main()` / DI 注册 / 路由表 / **已实例化的 controller·单例的初始状态** / 全局变量 | **② 热重启** `kill -USR2`(清状态重跑 main,复用已编译产物,比冷启快) |
| **codegen 的输入**:`.arb`/l10n 文案、freezed·json_serializable 注解、drift schema | **先跑生成器**(`gen-l10n` / `build_runner`)**再 ② USR2**——只发 USR1 会看到旧产物,极易误判成"改了没生效"而去瞎改代码 |
| `android/`·`ios/` 原生 / `pubspec.yaml`(增删依赖·assets) / 含原生码的新插件 / engine·channel | **③ 冷启动**(停掉重 `flutter run`) |

口诀:Dart 方法体→USR1;初始化/注册/main/路由→USR2;**codegen 输入→先生成再 USR2**;动原生/pubspec/插件→冷启动;**拿不准先 USR2**(仍比冷启快)。

> **临时诊断日志给一个独特前缀**(`[分页诊断]`、`[登录诊断]` …)。它是你在满是第三方噪音的 logcat 里 grep 出自己日志的抓手,更是提交前 grep 一遍**证明自己删干净了**的抓手。打**决定性的值**,不要打「到这儿了」:打那个决定走了哪条分支的状态(`isSuccess=false`、游标、列表长度)。一行选得好的日志,通常能直接终结一场本来要靠截图和猜测拖上好几轮热重载的调查。USR1 加进去、读完、删掉再 USR1。

> **要回查重载成败,就换一条带回执的通道**:`kill -USR1` 发出去没有回执,只能回头 grep 输出猜。要确认"这次重载到底成没成"时走 `flutter run --machine` 的 `app.restart`——它**返回 `{"code":0,"message":"Reloaded N libraries"}`**,`code!=0` 直接就是断言。见 `references/vm-service.md` §2.4。日常随手重载仍用 signal 更省事。

---

## 收尾清理(kill flutter run ≠ 关 App)+ 防串台

**防串台**:同设备可共存多个 App(applicationId/bundleId 不同、互不覆盖)。截图/点击前确认前台=目标包:`mobilecli apps foreground --device <id>`(或 Android `adb ... dumpsys activity activities | grep mResumedActivity`);读日志先认目标 App PID(所有 Flutter App 的 `I/flutter` 都进 logcat)。

**收尾两步 + 回查**(`kill flutter run` 只断宿主,设备 App 照跑):
```bash
kill "$(cat <PID_FILE>)" 2>/dev/null                      # 1) 停 flutter run 宿主
mobilecli apps terminate --device <id> <packageName>      # 2) 真关 App(Android=am force-stop / iOS=simctl terminate,mobilecli 已抹平)
# 3) 同设备别项目残留 App 也 terminate;回查前台确认不是残留 App
```
**宣布"测完/停好"前先回查真实状态**。测试中改过的**设备系统状态同样要复原 + 回查**——断过网必须验证网络已恢复(`svc wifi enable` 在部分机型会卡死,可靠恢复路径见 `references/android.md` §10);关过动画、禁过输入法同理,**输入法要还原成原本启用的那份清单和原本的默认输入法**,别拿清单第一行顶包(§4.2 / §4.4)。

---

## 平台细节、进阶与可移植性

- **VM Service 内省** → `references/vm-service.md`(第三条路:widget 树带源码行号 / render 树真实尺寸 / 结构化错误 / evaluate 读状态 / 运行时切深色模式;HTTP 与 WS 的能力边界)
- **iOS 对等** → `references/ios.md`(`xcrun simctl` 模拟器优先 / WebDriverAgent 真机 / go-ios / 设备信任·provisioning / 确定性开关 / 收尾 terminate)
- **Android 细节** → `references/android.md`(adb 路径/wm size/dumpsys/logcat/关动画等确定性开关/输入法禁用与还原/性能指标/断网测试与恢复,平台末选)
- **离线测试层** → `references/offline-test-layer.md`(fixture 四策略 + widget test + golden 矩阵 + a11y guideline)
- **跨屏验证** → `references/cross-screen-verification.md`(一屏看不出的性质:分页顺序 / 跨页不重复 / 能否到底——逐屏采集、拼接、用代码断言;附三个坑:先校准尺子、「画面不动」有三种意思、原始数据别进上下文)
- **工具选型** → `references/tool-decision-tree.md`(mobilecli/mobile-mcp/mobilewright/Patrol 何时用)
- **受限网络/权限** → `references/restricted-network.md`(npm 被企业网关拦时的备用渠道、macOS 执行位与 quarantine、哪些卡点只能人给)
- **规模化/无人值守** → `references/scaling.md`(信任阶梯、worktree/子代理/workflow 并行、/schedule·/loop)
- **项目落地**:`templates/`(`.claude/settings.json` 权限白名单+format/analyze hook + `.claude/commands/{spec,verify,ship,debug,nightly}.md`)。一键装:`bash setup-project.sh <项目根>`,**只往 `.claude/` 里写,不动你的项目根**(见 README)。

---

## Rules — 硬原则核对表(一条不丢;机制在各自章节,这里只做核对)

**Always 永远要**
1. 先环境自举;**绿区**的事自己做完接着干(§2)。
2. 交互前先 `dump ui` 检视,按 Key/label 定位、取**面积最小**的匹配;`io swipe`/长按发完**回查**(§元素驱动交互)。
3. 可交互/可断言控件双标 `Key` + `Semantics`;`dump ui` 列不出 = 回代码补,并用 `meetsGuideline` 让它以后自动被拦住(§代码契约)。
4. **改了 UI 就必须上设备真跑一次并截图核验**——`flutter test` 全绿**不等于** UI 对(§验证分层「← 向上」);任务里出现「跑起来看看/效果怎么样/是不是错位」一律上设备,不许用"单测通过"结案。
5. 纯逻辑 bug 用离线层秒级定位、静态视觉回归交给 golden——**目的是把设备时间留给真正要看 UI 的部分**。
6. 验收标准先自展开成 3~8 条可断言条目并逐条标层;每条开跑前**复位到已知起点**;跑几端按改动性质定,单端绿如实写成单端绿,模拟器给不了的能力直接上真机(§自主开发完整循环)。
7. 找不到控件 / 布局歪 / 疑似报错,**先查 VM Service**(widget 树带源码行号、render 树给真实 constraints),别一上来就截图肉眼找。
8. 改代码走 `--pid-file` + `USR1`/`USR2`;改了 codegen 输入(`.arb`/freezed/drift)**先跑生成器再 USR2**;要**回查**重载成败走 `--machine` 的 `app.restart`。等构建给全「起来了/死了/超时」三个出口。临时诊断日志统一带**一个独特前缀**——既是读它时的过滤条件,也是提交前证明「一条不剩全删干净」的依据(§flutter run 后台化)。
9. 收尾两步关 App 并**回查**前台;**不回查不报完成**。
10. 断言失败=逻辑 bug,修实现不改测试;自修复 **≤5 轮**(第3轮记已试方向、第4轮换思路、第5轮停下出卡住报告,继续下个任务)。**改完之后要把原本通过的条目也重跑一遍**——动了规模/时序/频率(分页大小、超时、轮询间隔、并发)的改动,会把所有原本靠运气赢的竞态挪一遍。
11. 报告按**完成门槛**五项出齐,缺一项不算完成。
12. 提交按用户提交策略执行(§1),不默认自动提交。

**Never — 四红线**(默认禁止,唯一解锁=用户事先明确授权并写明范围;详见 §2):① 设备物理掉线(自救一次仍败才停) ② 花真钱的操作 ③ 密钥/凭证操作 ④ 不可逆破坏 + 项目 `CLAUDE.md` 特有红线。未授权时:交互可问一句,无人值守跳过并标注「需授权」,不卡住等人。

**Never — 两条反模式**(其余失败形态都是上面 Always 的反面,正面读那一条即可):
- **不回查就报结果**——设备侧命令失败时退出码常常是 0,「我执行了」离「它生效了」还差一次回查(最常见:拿 `io swipe` 的退出码 0 当滑动成功)。
- **拿"离线测试全绿"当"UI 验过了"**——头号反模式:该上设备的没上,报告里没有一张截图。

> 后者**最该防**:前者是效率与准确性问题,它是**没干活却报了完成**——本 skill 的价值就在那张截图和那次真跑上。

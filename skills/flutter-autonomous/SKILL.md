---
name: flutter-autonomous
license: MIT
compatibility: Requires Flutter SDK; Android via adb (mac/Linux); iOS via Xcode/simctl (macOS only); mobilecli/patrol_cli auto-installed by scripts/bootstrap.sh
metadata:
  author: z-chu
  version: "1.1.0"
description: Flutter 真机/模拟器自主运行与 UI 验证(iOS + Android 对等)。用于:把 App 跑到设备/模拟器上看效果、模拟点击/输入/滑动、截图视觉核验、抓日志定位、E2E/集成回归(Patrol 按 Key),或自主跑「实现→上设备验证→修复→提交」闭环。**要 App 真跑起来看 UI 才用它;纯写单测/纯逻辑测试不用本 skill**(直接 flutter test 即可)。Autonomous Flutter on-device/simulator UI verification: tap/screenshot/log evidence, Patrol E2E regression. Not for writing plain unit tests.
---

# Flutter 自主开发与真机/模拟器测试

你进入「Flutter 自主开发模式」:无人监督下跑完 需求 → 实现 → 测试 → 修复 → 提交 的闭环,直到任务清单做完或达重试上限。方法论在本文与 `references/`,**项目特定值(包名/设备/dart-define/日志锚点/工具链/共存 App/业务红线)一律从项目根 `CLAUDE.md` 读**,没有就用 `templates/CLAUDE.md` 起一份(见 §可移植性)。iOS 与 Android 对等——交互底座统一 `mobilecli`,平台差异封装在 `references/{ios,android}.md`。

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
- **设备** ← §2 自举后运行时 `mobilecli devices` 现取,**绝不把设备 id 写进任何文件**
- **日志锚点 / 工具链约束(JDK/Xcode)/ 同设备共存 App / 业务红线** ← 项目 `CLAUDE.md`
- **提交策略(开工前问一句)** ← **提交不是本 skill 的职责**:要不要 commit、怎么 commit(干一点提交一点 / 干完再统一提 / 不提交 / 其它要求)**由用户定**。项目 `CLAUDE.md` 的 `{{COMMIT_POLICY}}` 或本次指令已说明就照做;**没说就先问一句再开跑**,问清后整个过程按它执行。提交规范(精确 `git add`、message 格式、是否 push、署名)以用户**全局 / 项目 `CLAUDE.md`** 为准,别在这里替用户定。

读不到就先建项目 `CLAUDE.md`(`templates/CLAUDE.md` 照填),别拿写死的值往下跑。

---

## 2. 环境自举:缺工具/依赖就自己装好,别停下要人工

上下文清楚后立刻补齐工具——**绿区(见下)的事自己做完接着干,绝不停下要人工**。
(教训:mobile-mcp 没注册 → 退回最低效的盲点 adb → 撞红线被拦 → 停下要人工。本该自检时就装好。)

一把梭:`bash scripts/bootstrap.sh`(跨平台 mac/Linux、Android+iOS,幂等可重入:每项 **检测→缺则装→独立命令回验→已装跳过**)。手动逐项:

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

**红线(默认禁止,用户事先明确授权才做)**:① 设备物理掉线/没插——物理阻塞,自救一次仍失败才停下报告;② 花真钱/影响真实用户的操作(支付/扣费/转账/下单;区块链 App 的上链交易同理);③ 密钥/凭证操作(生产密钥/签名证书/用户凭证/私钥助记词);④ 不可逆破坏(删数据/改生产)。②③④ **默认一律不做**,唯一解锁方式是用户**事先明确授权**——本次指令说明,或项目 `CLAUDE.md` 的 `{{AUTHORIZED_REDLINE_EXCEPTIONS}}` 写明允许哪类、什么范围(如「沙箱支付可下单」「测试链可发交易」),且只做写明的范围。未授权时:交互会话可停下问一句;**无人值守不问不等——跳过该项、报告标注「需授权:<操作>」,继续下个任务**。绝不把「测试需要」当授权。项目特有红线在 `{{IRREVERSIBLE_REDLINES}}` 里补充,同等效力。

**绿区(红线之外的一切)**:装工具、改本地配置、补依赖、scaffold 测试、起停模拟器、装 WDA/agent——可逆、低风险,**自己做完接着干**,别把"工具没装好"当停下理由。全文再提「绿区」都指这一条。

**装不上时先分清「渠道」还是「权限」**:
- **渠道问题**(包管理源被挡,典型是企业网关拦 npm):**仍在绿区**——绿区看的是「目标」不是「渠道」,换条路继续。`bash scripts/bootstrap.sh` 已内置 GitHub Releases 自动回退;手动做法与坑 → `references/restricted-network.md`。
- **权限问题**(只有人在 GUI 里能给:macOS 辅助功能、设备「允许 USB 调试」、iOS 开发者模式、`xcode-select --install` 弹窗):**真停**,和设备物理掉线同级。交互可问一句;无人值守跳过并在报告写明「需人工授权:在哪点什么」,继续下个任务。

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
D=$(mobilecli devices | jq -r '.data.devices[0].id')   # 输出是 {status,data:{devices:[…]}};或从项目 CLAUDE.md 读
mobilecli apps launch     --device "$D" <packageName>   # 拉前台
mobilecli apps foreground --device "$D"                 # 确认前台=目标包(防串台)
mobilecli dump ui         --device "$D" > "$UI"         # label + 设备像素 rect{x,y,width,height}
# 按 label 挑目标,点 rect 中心 (x+width/2, y+height/2):
mobilecli io tap   --device "$D" <cx>,<cy>
mobilecli io swipe --device "$D" x1,y1,x2,y2            # 滑块/列表滚动/下拉刷新
mobilecli io text  --device "$D" "文本"                 # 系统输入框
mobilecli io button --device "$D" BACK                  # 退回(iOS 无 BACK,用手势/导航栏 tap)
mobilecli screenshot --device "$D" -o "$SHOT"           # 截图 → Read 核验
```

**Flutter 定位优先级(由稳到脆)**:Patrol `Key`(回归最稳) > `Semantics` label 精确 > role/`button:true` 标志 > label 子串/正则 > 纯文本 > 盲点坐标(末选)。

要点:坐标取 `dump ui` rect 中心**不盲猜**;每步 `screenshot`+Read 核验,点错 `io button BACK` 退回;Flutter **自绘数字键盘/自定义手势控件不是系统输入框**,`io text` 喂不进 → 逐个 `io tap` 键坐标;**WDA 合成的 `io longpress` Flutter 侧可能不认**(如 AppBar 标题上的 `GestureDetector` 长按),别硬扛——按下面「列不出=回代码补」同一条原则,把隐藏手势换成有 `Semantics` 的可点控件,顺带人工测试也更好用;某控件列不出 = 没暴露 Semantics → **回代码补**(下),别将就盲点。深链跳关:`mobilecli device url <deeplink>` 直达页面,省逐级导航。

---

## 代码契约:每个可交互/可断言控件加 Key + Semantics

两条路各吃一样,都加上,控件才"天生可测":`Key` 给 Patrol(命名 `<功能>_<控件类型>` 小写下划线);`Semantics(label:)` 给元素驱动。标准 `Text`/`ElevatedButton` 文本自带 label;**自定义手势控件(`Touchable`/`GestureDetector`/`InkWell`)默认列不出,务必显式包 `Semantics(label+button:true)`**。

```dart
ElevatedButton(key: const Key('submit_btn'), onPressed: _submit, child: const Text('提交'))

Semantics(label: '滑动买入', button: true,           // 自定义手势:不包 Semantics 就 dump 不出
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

**← 向上(不许拿离线绿冒充 UI 验过)——这条更重要**:
- **离线全绿 ≠ UI 没问题。** widget test 跑在无头测试环境,不经真实渲染管线、没有真实字体度量、没有平台通道、没有真机时序。它能证「逻辑上该显示 X」,**证不了「真机上看起来对」**。
- 凡是任务里说了**「跑起来看看」「效果怎么样」「是不是错位/截断/糊了」「在真机上试试」**——**必须上设备**,截图 Read 核验,**不许用"单测已通过"结案**。
- 任何改了 UI 的改动,**收工前至少上设备真跑一次并截图**;golden 只是回归网,不替代"这次改完亲眼看一眼"。
- **不确定该不该上设备时,上。** 本 skill 的成本模型里,漏看一次 UI 的代价远大于多跑一次设备。

**层内选择(已经决定要上设备之后)**:「控件找不到 / Key 对不对 / 布局为什么歪」——**别先截图**,用 ④ 看 widget 树和 constraints,一步到源码行,再截图确认观感。

---

## 自主开发完整循环 + 失败决策树

```
读任务 → 自展开验收标准(3~8 条可断言,逐条标好落哪层)
  → 写实现(关键控件加 Key+Semantics)+ 写配套测试(离线①②③ 能覆盖的先写在离线层)
  → flutter analyze(零警告)
  → flutter test(离线层 ①②③)   ── 挂?逻辑/行为/视觉契约 bug,不上设备直接修
  → 确认设备在线(mobilecli devices;离线自救一次仍离线才停)
  → patrol test --device <id> -t integration_test/<feature>_test.dart
      ├─ 通过 → 截图核验 → (按用户提交策略:增量提/最后提/不提)→ 输出报告
      └─ 失败 → 失败分析(≤5 轮;找不到控件先查 VM Service widget 树)→ 修 → 重跑
                5 轮仍败 → 停,出卡住报告,继续下个任务
```

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

**启动**:命令**必须以 `flutter run` 开头**(若你的权限规则按前缀匹配如 `Bash(flutter run:*)`,nohup/管道/`&` 包裹会被拦),后台化靠 `run_in_background: true` 参数;带 `--pid-file`(默认 `/tmp/flutter_app.pid`,多设备/会话并发时拼项目或设备后缀避免撞)。

```bash
flutter run -d <deviceId> --target <entry> \
  --pid-file=<PID_FILE> --vmservice-out-file=<URI_FILE> <dart-defines 从项目 CLAUDE.md 读>
```

**等构建**(长驻进程不自发完成通知,另起后台 Bash 轮询)。**优先等 `--vmservice-out-file` 落盘**——文件非空 = App 起来且 VM Service 就绪,是个二值信号,不用解析人类可读输出;失败仍需看输出兜底:

```bash
until [ -s "<URI_FILE>" ] || grep -qE "FAILURE:|Gradle task .* failed|Error launching" <output>; do sleep 2; done
```

拿到的 URI 顺带就是 §验证分层④ 的入口(转 http 后一行 curl 取 widget 树/布局/错误),见 `references/vm-service.md`。

**三档热重载铁律**(启动必带 `--pid-file`,否则发不了信号,每改一行冷启浪费几十分钟):

| 改了什么 | 用哪档 |
|---|---|
| UI/样式/方法体/普通逻辑 | **① 热重载** `kill -USR1 $(cat <PID_FILE>)`(注入新代码,保留状态) |
| 字段初始化器 / `main()` / DI 注册 / 路由表 / **已实例化的 controller·单例的初始状态** / 全局变量 | **② 热重启** `kill -USR2`(清状态重跑 main,复用已编译产物,比冷启快) |
| `android/`·`ios/` 原生 / `pubspec.yaml`(增删依赖·assets) / 含原生码的新插件 / engine·channel | **③ 冷启动**(停掉重 `flutter run`) |

口诀:Dart 方法体→USR1;初始化/注册/main/路由→USR2;动原生/pubspec/插件→冷启动;**拿不准先 USR2**(仍比冷启快)。

> **要判热重载成败时别用 signal**:`kill -USR1` 发出去就没下文,只能回头 grep 输出猜。改完代码必须确认"这次重载到底成没成"时,走 `flutter run --machine` 的 `app.restart`——它**返回 `{"code":0,"message":"Reloaded N libraries"}`**,`code!=0` 直接就是断言。见 `references/vm-service.md` §2.4。日常随手重载仍用 signal 更省事。

---

## 收尾清理(kill flutter run ≠ 关 App)+ 防串台

**防串台**:同设备可共存多个 App(applicationId/bundleId 不同、互不覆盖)。截图/点击前确认前台=目标包:`mobilecli apps foreground --device <id>`(或 Android `adb ... dumpsys activity activities | grep mResumedActivity`);读日志先认目标 App PID(所有 Flutter App 的 `I/flutter` 都进 logcat)。

**收尾两步 + 回查**(`kill flutter run` 只断宿主,设备 App 照跑):
```bash
kill "$(cat <PID_FILE>)" 2>/dev/null                      # 1) 停 flutter run 宿主
mobilecli apps terminate --device <id> <packageName>      # 2) 真关 App(Android=am force-stop / iOS=simctl terminate,mobilecli 已抹平)
# 3) 同设备别项目残留 App 也 terminate;回查前台确认不是残留 App
```
**宣布"测完/停好"前先用独立命令回查真实状态**,别拿"我执行了 kill"当"App 关了"。测试中改过的**设备系统状态同样要复原 + 回查**——断过网必须验证网络已恢复(`svc wifi enable` 在部分机型会卡死,可靠恢复路径见 `references/android.md` §10)。

---

## 平台细节、进阶与可移植性

- **VM Service 内省** → `references/vm-service.md`(第三条路:widget 树带源码行号 / render 树真实尺寸 / 结构化错误 / evaluate 读状态 / 运行时切深色模式;HTTP 与 WS 的能力边界)
- **iOS 对等** → `references/ios.md`(`xcrun simctl` 模拟器优先 / WebDriverAgent 真机 / go-ios / 设备信任·provisioning / 确定性开关 / 收尾 terminate)
- **Android 细节** → `references/android.md`(adb 路径/wm size/dumpsys/logcat/关动画等确定性开关/性能指标/断网测试与恢复,平台末选)
- **离线测试层** → `references/offline-test-layer.md`(fixture 四策略 + widget test + golden 矩阵 + a11y guideline)
- **工具选型** → `references/tool-decision-tree.md`(mobilecli/mobile-mcp/mobilewright/Patrol 何时用)
- **受限网络/权限** → `references/restricted-network.md`(npm 被企业网关拦时的备用渠道、macOS 执行位与 quarantine、哪些卡点只能人给)
- **规模化/无人值守** → `references/scaling.md`(信任阶梯、worktree/子代理/workflow 并行、/schedule·/loop)
- **项目落地**:`templates/`(CLAUDE.md 宪法模板 + `.claude/settings.json` 权限白名单+format/analyze hook + `.claude/commands/{spec,verify,ship,debug,nightly}.md`)。一键装:`bash setup-project.sh <项目根>`(见 README)。

---

## Rules — 硬原则核对表(一条不丢;机制在各自章节,这里只做核对)

**Always 永远要**
1. 先环境自举;**绿区**的事自己做完接着干(§2)。
2. 交互前先 `dump ui` 检视,按 Key/label 定位,坐标取 rect 中心。
3. 可交互/可断言控件双标 `Key` + `Semantics`;`dump ui` 列不出 = 回代码补,并用 `meetsGuideline(labeledTapTargetGuideline)` 让它以后自动被拦住。
4. **改了 UI 就必须上设备真跑一次并截图核验**——`flutter test` 全绿**不等于** UI 对(无头环境不经真实渲染)。任务里出现「跑起来看看/效果怎么样/是不是错位」一律上设备,不许用"单测通过"结案;拿不准该不该上,就上。
5. 纯逻辑 bug 用离线层秒级定位,别占真机时间;静态视觉回归交给 golden——**这是为了把设备时间留给真正要看 UI 的部分**,不是少上设备的借口。
6. 找不到控件 / 布局歪 / 疑似报错,**先查 VM Service**(widget 树带源码行号、render 树给真实 constraints),别一上来就截图肉眼找。
7. 改代码走 `--pid-file` + `USR1`/`USR2`,不冷启;**要判重载成败用 `--machine` 的 `app.restart`**,别 grep 输出猜。
8. 收尾两步关 App 并**回查确认**;**不验证不报完成**。
9. 断言失败=逻辑 bug,修实现不改测试;自修复 **≤5 轮**(第3轮记已试方向、第4轮换思路、第5轮停下出卡住报告,继续下个任务)。
10. 报告按**完成门槛**五项出齐,缺一项不算完成。
11. 提交按用户提交策略执行(§1),不默认自动提交。

**Never — 四红线**(默认禁止,唯一解锁=用户事先明确授权并写明范围;详见 §2):① 设备物理掉线(自救一次仍败才停) ② 花真钱的操作 ③ 密钥/凭证操作 ④ 不可逆破坏 + 项目 `CLAUDE.md` 特有红线。未授权时:交互可问一句,无人值守跳过并标注「需授权」,不卡住等人。

**Never — 反模式**:有 Semantics 还盲点 / 写死历史坐标 / 把 `kill flutter run` 当关 App / 改测试绕过断言 / 把"执行了操作"当"达到了结果" / **拿"离线测试全绿"当"UI 验过了"**(头号反模式:该上设备的没上,报告里没有一张截图) / **纯逻辑 bug 拿真机时间去定位**(离线层秒级能定位到行) / **靠肉眼盯整屏截图做重复性视觉回归**(该固化成 golden 的固化掉)。

> 上面三条反模式里,**第一条最该防**。后两条是效率问题,第一条是**没干活却报了完成**——本 skill 的价值就在那张截图和那次真跑上。

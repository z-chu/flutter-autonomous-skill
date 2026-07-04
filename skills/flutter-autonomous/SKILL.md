---
name: flutter-autonomous
license: MIT
compatibility: Requires Flutter SDK; Android via adb (mac/Linux); iOS via Xcode/simctl (macOS only); mobilecli/patrol_cli auto-installed by scripts/bootstrap.sh
metadata:
  author: z-chu
  version: "1.0.0"
description: Flutter 真机/模拟器自主运行与自动化测试验证(iOS + Android 对等)。用于:把 Flutter App 跑到设备/模拟器上看效果、E2E/集成回归(Patrol 按 Key)、离线 fixture 秒级单测、截图视觉核验、模拟点击/输入/滑动、抓日志定位、打包,或自主跑「实现→测试→修复→提交」闭环。Flutter 画在 canvas、无障碍树默认空——控件暴露 Semantics label 后用 mobilecli/mobile-mcp 列元素+设备像素坐标精准点(首选,远胜盲点坐标);iOS 经 WebDriverAgent/xcrun simctl、Android 经 adb,底座统一 mobilecli。缺工具/依赖能自己装就装好再继续。Autonomous Flutter on-device/simulator run & test verification for iOS and Android — running the app on a device/simulator, E2E/integration regression (Patrol by Key), fast offline fixture unit tests, screenshots, simulated taps/typing/swipes, log capture, packaging, or self-driving implement→test→fix→commit loops.
---

# Flutter 自主开发与真机/模拟器测试

你进入「Flutter 自主开发模式」:无人监督下跑完 需求 → 实现 → 测试 → 修复 → 提交 的闭环,直到任务清单做完或达重试上限。方法论在本文与 `references/`,**项目特定值(包名/设备/dart-define/日志锚点/工具链/共存 App/业务红线)一律从项目根 `CLAUDE.md` 读**,没有就用 `templates/CLAUDE.md` 起一份(见 §可移植性)。iOS 与 Android 对等——交互底座统一 `mobilecli`,平台差异封装在 `references/{ios,android}.md`。

> 英文镜像见 `en/SKILL.md` 与 `en/references/`;中文是 source of truth。

---

## 第一步:开工先收集上下文(项目无关化的地基)

动手前先把"这是哪个项目"问清楚,**自动探测、别问人、别写死**:

- **applicationId**(Android)← `android/app/build.gradle(.kts)` 的 `applicationId`
- **bundleId**(iOS)← `ios/Runner.xcodeproj/project.pbxproj` 的 `PRODUCT_BUNDLE_IDENTIFIER`(或 Flutter `pubspec.yaml` 的 `patrol:` 段)
- **入口 / dart-defines** ← `.vscode/launch.json` 的 debug 配置 或 项目 `CLAUDE.md`
- **设备** ← 运行时 `mobilecli devices`(下面),**绝不把设备 id 写进任何文件**
- **日志锚点 / 工具链约束(JDK/Xcode)/ 同设备共存 App / 业务红线** ← 项目 `CLAUDE.md`
- **提交策略(开工前问一句)** ← **提交不是本 skill 的职责**:要不要 commit、怎么 commit(干一点提交一点 / 干完再统一提 / 不提交 / 其它要求)**由用户定**。项目 `CLAUDE.md` 的 `{{COMMIT_POLICY}}` 或本次指令已说明就照做;**没说就先问一句再开跑**,问清后整个测试过程按它执行。本 skill 只管让自主测试跑得顺,不替用户决定提交。

读不到就先建项目 `CLAUDE.md`(`templates/CLAUDE.md` 照填),别拿写死的值往下跑。

---

## 0. 环境自举:缺工具/依赖就自己装好,别停下要人工

进自主模式**第一件事**是补齐工具——**能自己装/配的绝不停下要人工**。
(教训:mobile-mcp 没注册 → 退回最低效的盲点 adb → 撞红线被拦 → 停下要人工。本该自检时就装好。)

一把梭:`bash scripts/bootstrap.sh`(跨平台 mac/Linux、Android+iOS,幂等可重入:每项 **检测→缺则装→独立命令回验→已装跳过**)。手动逐项:

| 检查 | 命令 | 缺了怎么办(自己做) |
|---|---|---|
| 设备在线 | `mobilecli devices`(空再 `adb devices` / `xcrun simctl list devices booted`) | 都空:Android `adb kill-server && adb start-server` 自救一次;iOS 模拟器 `xcrun simctl boot <udid>`;仍空=**物理掉线/没起,才停** |
| **mobilecli**(交互底座) | `mobilecli --version` | 缺 → `npm i -g mobilecli@latest`(或 `npx mobilecli@latest` / 源码 `make build`)。已装即用,**无需 MCP/重启** |
| **mobile-mcp**(MCP 版,可选) | `claude mcp list \| grep -i mobile` | 缺 → `claude mcp add mobile-mcp -- npx -y @mobilenext/mobile-mcp@latest`(**改 MCP 配置=下次会话才连**;本会话先用 mobilecli 顶,别因此退回盲点) |
| **patrol_cli** | `patrol --version` | 缺 → `dart pub global activate patrol_cli`;装了报 not found → `export PATH="$PATH:$HOME/.pub-cache/bin"` |
| 项目 Patrol 配置 | pubspec 有 `patrol` dev_dep + `patrol:` 段 + `integration_test/` | 缺 → `flutter pub add patrol --dev` + 补 `patrol:` 段 + Android `androidTest` 脚手架。项目级一次性投入,**装好继续** |
| node(npx 用) | `node -v`(需 v22+) | 缺 → fnm/nvm 装 |
| **iOS 专属**(仅 mac) | 见 `references/ios.md` | Xcode CLT、模拟器、真机走 WDA+provisioning(真机装 agent 直接用 app 自身 `build/ios/Debug-iphoneos/Runner.app/embedded.mobileprovision`);Linux 无 iOS 工具链,自动只跑 Android |

`npx mobilewright doctor --json` 可作跨平台体检入口(覆盖 Node/mobilecli/Xcode/Simulators/agent/Java/ADB),再叠 `flutter doctor` + patrol。详见 `references/android.md`、`references/ios.md`。

**红线(默认禁止,用户事先明确授权才做)**:① 设备物理掉线/没插——物理阻塞,自救一次仍失败才停下报告;② 花真钱/影响真实用户的操作(支付/扣费/转账/下单;区块链 App 的上链交易同理);③ 密钥/凭证操作(生产密钥/签名证书/用户凭证/私钥助记词);④ 不可逆破坏(删数据/改生产)。②③④ **默认一律不做**,唯一解锁方式是用户**事先明确授权**——本次指令说明,或项目 `CLAUDE.md` 的 `{{AUTHORIZED_REDLINE_EXCEPTIONS}}` 写明允许哪类、什么范围(如「沙箱支付可下单」「测试链可发交易」),且只做写明的范围。未授权时:交互会话可停下问一句;**无人值守不问不等——跳过该项、报告标注「需授权:<操作>」,继续下个任务**。绝不把「测试需要」当授权。项目特有红线在 `{{IRREVERSIBLE_REDLINES}}` 里补充,同等效力。**除此之外**——装工具、改本地配置、补依赖、scaffold 测试,都是可逆低风险,**做完接着干**,别把"工具没装好"当停下理由。

---

## 核心认知:Flutter 控件怎么找——两条互补的路

Flutter 用 Skia/Impeller 画 canvas,系统无障碍树**默认**几乎空,但这**不等于找不到控件**:

1. **Dart VM 直连(Patrol / integration_test)**:走 widget 树按 `Key` 精确查找+断言,**可复跑、出 pass/fail**。→ **确定性回归**用它。这是 Flutter 唯一不依赖无障碍树暴露、iOS/Android 都稳的断言路径。
2. **无障碍树驱动(mobilecli `dump ui` / mobile-mcp `list_elements`)**:**只要控件暴露 `Semantics` label**,返回 label + **设备像素 rect**,取中心直接点,无需换算。→ **交互式探索/导航/一次性验证**用它,比盲点坐标又快又准。

只有**纯 canvas 绘制**(图表内部、无 Semantics 包裹的元素)两条都找不到——那种才回退「截图肉眼 + 量坐标换算」。

---

## 工具决策树(底座都是 mobilecli,别无脑用 adb)

| 场景 | 用什么 | 关键 |
|---|---|---|
| **即时交互/探索/诊断**(自主跑首选) | **mobilecli** | 已装二进制,免 MCP/重启;`dump ui`→`io tap` 坐标级 |
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

要点:坐标取 `dump ui` rect 中心**不盲猜**;每步 `screenshot`+Read 核验,点错 `io button BACK` 退回;Flutter **自绘数字键盘/自定义手势控件不是系统输入框**,`io text` 喂不进 → 逐个 `io tap` 键坐标;某控件列不出 = 没暴露 Semantics → **回代码补**(下),别将就盲点。深链跳关:`mobilecli device url <deeplink>` 直达页面,省逐级导航。

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

> 自查:`dump ui` 列不出你的控件 = 没暴露 Semantics → 回代码补 `Semantics(label:)`,把"测不到"当代码缺陷修,别降级盲点。

---

## 验证四层:按改动类型选最硬的证据

| 层 | 验什么 | 怎么验 |
|---|---|---|
| ① **离线 fixture(秒级,无设备)** | 解码/解析/数值/状态机/错误处理等纯逻辑 | `flutter test` / `dart test` + fixture/mock,见 `references/offline-test-layer.md`(真实数据 JSON / 手搓字节 / forTesting 注入 / probe 四策略) |
| ② **元素驱动(一次性)** | 控件交互/页面跳转/数据展示 | `dump ui`→点中心 + 截图 |
| ③ **Patrol(可复跑)** | 同②但要回归断言、进 CI | 按 Key,出 pass/fail |
| ④ **日志 / 截图(取证)** | 连接/状态机/gating 用**日志**(最硬);视觉/布局用**截图** | `adb logcat -s flutter`(Android)/`flutter logs` / `xcrun simctl spawn <udid> log stream`(iOS);grep 连接URL/状态名/`RenderFlex overflowed`(带文件:行号) |

**闭环顺序**:`flutter analyze` → `flutter test`(离线层,秒级) → 元素驱动(一次性) → Patrol(可复跑)。**离线层先绿再上设备**,省设备时间;能离线证明的逻辑别上真机。

---

## 自主开发完整循环 + 失败决策树

```
读任务 → 自展开验收标准(3~8 条可断言) → 写实现(关键控件加 Key+Semantics)+ 写 Patrol/离线测
  → flutter analyze(零警告)
  → flutter test(离线层)        ── 挂?纯逻辑 bug,不上设备直接修
  → 确认设备在线(mobilecli devices;离线自救一次仍离线才停)
  → patrol test --device <id> -t integration_test/<feature>_test.dart
      ├─ 通过 → 截图核验 → (按用户提交策略:增量提/最后提/不提)→ 输出报告
      └─ 失败 → 失败分析(≤5 轮)→ 修 → 重跑;5 轮仍败 → 停,出卡住报告,继续下个任务
```

**失败分类**:编译错→`flutter analyze` 读错误修;`found 0 widgets`→查 Key 拼写/是否需 scroll/条件渲染;断言失败→**逻辑 bug 改实现,不改测试降标准**;crash/超时→`mobilecli device crashes list|get` 读堆栈第一行 `package:<your_app>/`;安装/连接→`mobilecli devices` + 自救一次仍失败停。

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

## flutter run 后台化 + 三档热重载(别动不动冷启)

**前置**:同设备若被别的 `flutter run` 占用(如 VS Code 调试),先释放——`ps aux | grep "flutter_tools.snapshot run" | grep -v grep`,有则提示用户停掉再继续,不强启。

**启动**:命令**必须以 `flutter run` 开头**(若你的权限规则按前缀匹配如 `Bash(flutter run:*)`,nohup/管道/`&` 包裹会被拦),后台化靠 `run_in_background: true` 参数;带 `--pid-file`(默认 `/tmp/flutter_app.pid`,多设备/会话并发时拼项目或设备后缀避免撞)。

```bash
flutter run -d <deviceId> --target <entry> --pid-file=<PID_FILE> <dart-defines 从项目 CLAUDE.md 读>
```

**等构建**(长驻进程不自发完成通知,另起后台 Bash 轮询):
```bash
until grep -qE "Flutter run key commands|FAILURE:|Gradle task .* failed|Error launching" <output>; do sleep 3; done
```

**三档热重载铁律**(启动必带 `--pid-file`,否则发不了信号,每改一行冷启浪费几十分钟):

| 改了什么 | 用哪档 |
|---|---|
| UI/样式/方法体/普通逻辑 | **① 热重载** `kill -USR1 $(cat <PID_FILE>)`(注入新代码,保留状态) |
| 字段初始化器 / `main()` / DI 注册 / 路由表 / **已实例化的 controller·单例的初始状态** / 全局变量 | **② 热重启** `kill -USR2`(清状态重跑 main,复用已编译产物,比冷启快) |
| `android/`·`ios/` 原生 / `pubspec.yaml`(增删依赖·assets) / 含原生码的新插件 / engine·channel | **③ 冷启动**(停掉重 `flutter run`) |

口诀:Dart 方法体→USR1;初始化/注册/main/路由→USR2;动原生/pubspec/插件→冷启动;**拿不准先 USR2**(仍比冷启快)。

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

## 提交:不是本 skill 的职责

要不要提交、怎么提交,**由用户的提交策略定,本 skill 不规定也不默认自动提交**——它只负责让自主测试跑得顺。开工前用户没说就先问一句(干一点提交一点 / 干完再统一提 / 不提交 / 其它要求),问清后照做。具体提交规范(精确 `git add`、message 格式、是否 push、署名等)以用户**全局 / 项目 `CLAUDE.md`** 为准,别在这里替用户定。

---

## 平台细节、进阶与可移植性

- **iOS 对等** → `references/ios.md`(`xcrun simctl` 模拟器优先 / WebDriverAgent 真机 / go-ios / 设备信任·provisioning / 收尾 terminate)
- **Android 细节** → `references/android.md`(adb 路径/wm size/dumpsys/logcat/断网测试与恢复,平台末选)
- **离线测试层** → `references/offline-test-layer.md`(fixture 四策略)
- **工具选型** → `references/tool-decision-tree.md`(mobilecli/mobile-mcp/mobilewright/Patrol 何时用)
- **规模化/无人值守** → `references/scaling.md`(信任阶梯、worktree/子代理/workflow 并行、/schedule·/loop)
- **项目落地**:`templates/`(CLAUDE.md 宪法模板 + `.claude/settings.json` 权限白名单+format/analyze hook + `.claude/commands/{spec,verify,ship,debug,nightly}.md`)。一键装:`bash setup-project.sh <项目根>`(见 README)。
- **报告格式**:`✅/❌ 功能名` + 验收条件勾选(含第5轮失败标记)+ 改动文件 + 关键截图 +(若按策略提交了)Commit(hash+message)+ 遗留问题。

---

## Rules — Always / Never(硬原则,一条不丢)

**Always 永远要**
1. 进自主模式先环境自举;可逆低风险(装工具/改本地配置/补依赖/scaffold)自己做完接着干。
2. 交互前先 `dump ui` 检视,按 Key/label 定位,**别猜元素名**;坐标取 rect 中心(物理像素),元素驱动优先于盲点。
3. 每个可交互/可断言控件加 `Key`(Patrol)+ `Semantics`(元素驱动);自定义手势控件显式包 `Semantics`;列不出=回代码补,别将就盲点。
4. 能离线 fixture 秒级验的逻辑先离线过(`flutter test`),真机只验真机才能验的;能用日志证明的(连接/状态机)用日志,比截图可靠。
5. 改代码靠 `--pid-file` + `USR1`/`USR2` 信号热重载/重启,别动不动冷启。
6. 收尾两步关 App(停宿主 + `apps terminate`/force-stop)并**回查确认**;**不验证不报完成**——每个"做好/停好/提交"背后要有独立命令查真实状态。
7. 断言失败=逻辑 bug,**修实现不改测试降标准**;自修复**≤5 轮**,第3轮记已试方向、第4轮换思路、第5轮停下出卡住报告继续下个任务。
8. **提交不是本 skill 的职责**:要不要 / 怎么提交按用户提交策略(开工前问清:增量提 / 最后提 / 不提 / 其它);提交规范以用户全局 / 项目 `CLAUDE.md` 为准,别替用户决定,别默认自动提交。

**Never(四红线,默认禁止)**:① 设备物理掉线(自救一次仍败才停) ② 花真钱的操作(支付/转账/上链) ③ 密钥/凭证操作 ④ 不可逆破坏;外加项目 `CLAUDE.md` 的特有红线。②③④ 仅用户**事先明确授权**(本次指令或项目 `CLAUDE.md` 写明范围)才可做;未授权:交互可问一句,无人值守跳过并标注「需授权」,不卡住等人。除此自己做完接着干。
**Never 反模式**:有 Semantics 时盲点坐标 / 写死历史坐标(必须运行期从 dump 现取)/ 把 `kill flutter run` 当关 App / 改测试绕过断言 / 把"执行了操作"当"达到了结果"。

# 离线秒级测试层(无设备的三层)

> 本文是 [SKILL.md](../SKILL.md)「验证分层」里 **A. 离线层(①②③)** 的深度展开,术语/原则以 SKILL 为准,不与其矛盾。
> SKILL 已讲清「闭环顺序」「四红线」「自修复≤5轮」「断言失败修实现」等;这里只补 SKILL 没展开的**怎么写、怎么造数据、放哪、怎么跑**。

三层各管一段,**一条 `flutter test` 全跑完**:

| 层 | 管什么 | 本文位置 |
|---|---|---|
| ① **纯逻辑 fixture** | 解码/解析/数值/状态机/错误处理 | §3 四策略 |
| ② **widget test** | 控件交互、页面跳转、表单、条件渲染 | §4 |
| ③ **golden + a11y guideline** | 视觉回归矩阵、无障碍契约自检 | §5 |

> **最常被漏的是 ②③**。默认心智容易是"逻辑用单测、UI 就得上设备"——不对:大量"点一下看它变没变""看起来对不对"的验证,在 ②③ 里是**毫秒级、无设备、确定性**的。把它们放上设备,是拿几十分钟设备时间换本可秒级拿到的结论。

---

## 1. 为什么设备之外还要这几层(两块互补)

真机层(元素驱动 + Patrol + 截图)的本质是**集成 + 视觉**:慢、要设备、且**不确定**(联网、外部数据会变、有时序、有动画)。它证明不了、也不该用来证明这类问题:

- "这个解析器吃到脏/畸形数据时输出对不对?"
- "这个依赖外部 IO 的 service,在依赖抛异常 / 超时时会不会崩、会不会把内部错漏给上层?"
- "这段数值计算在某个量级下精度够不够?"

这些都是**纯逻辑**,应该有独立的一层来锁:**离线、确定性、秒级、无设备、CI 友好**。两层各管一段、互补:

| 层 | 锁什么 | 特征 |
|---|---|---|
| **离线层**(本文 ①②③) | 纯逻辑 + **控件交互/跳转** + **视觉回归/无障碍契约** | 把外部世界冻成确定性输入,秒级、无设备、每次 push 都能跑 |
| **设备层**(SKILL 主体) | 只剩:真实渲染、系统集成、真实数据、真机专属能力 | 需设备、慢、验真机才能验的东西 |

口诀:**能离线证明的,绝不上真机**。注意这句的范围比直觉大——不只是"逻辑",**交互和视觉的大部分也能离线证明**。真机时间只留给离线层够不着的那部分。

---

## 2. 闭环里的衔接位

离线层卡在 `flutter analyze` 之后、上设备之前:

```
flutter analyze(零警告)
  → flutter test / dart test   ← 【离线层 ①②③:本文】秒级、确定性、无设备
        ├─ ① 纯逻辑挂 = 逻辑 bug        ┐
        ├─ ② 交互/跳转挂 = 行为 bug      ├─ 全都【不上设备,直接修】
        └─ ③ golden/guideline 挂 = 视觉或无障碍契约 bug ┘
  → 确认设备在线 → VM Service 取证 / 元素驱动(一次性 dump→tap)
  → patrol test(可复跑断言,进 CI)
```

铁律:**离线层全绿才上设备**。`flutter test` 挂着就跑真机,是拿几十分钟的设备时间去定位本可秒级定位的纯逻辑 bug。
`/ship`、`/verify`、`/nightly` 等命令在 `flutter analyze` 之后、`patrol test` 之前,**都先插一步 `flutter test`**。

---

## 3. 第①层:纯逻辑 fixture 的四策略(按"被测对象吃什么"选)

被测对象吃外部 JSON/帧 → **A**;吃二进制字节流 → **B**;是依赖外部 IO 的 service,要测控制流/错误处理 → **C**;只是想探查真实数据分布、不进回归 → **D**。

---

### 策略 A:真实数据 → JSON fixture(测真实世界的脏数据)

**何时用**:代码要消费一个**外部数据源**(REST/GraphQL 回包、WebSocket 帧、外部 RPC、第三方 SDK 返回),而这数据 ① 会变 ② 有各种想不到的脏 / 边界 case ③ 联网慢且不稳。

**做法**:写一个**纯 Dart 抓取 CLI**(不 `import 'package:flutter/...'`,`dart run` 直接跑),把真实回包冻成 JSON,之后离线重放。CLI 给两个子命令,骨架很通用:

```dart
// tools/fetch_cli.dart —— 纯 Dart,不依赖 flutter,可直接 `dart run`
// 子命令:
//   list <query> [--limit=10]       列最近 N 条记录的 id + 状态(先挑要冻哪几条)
//   dump <id>    [--out=path.json]  抓单条完整响应,抽【最小字段子集】落 JSON
//
// 两个可复制的关键设计:
// 1) dump 时【只抽断言会用到的字段子集】,不要把整个响应原样存
//    —— fixture 要小、要稳、要能看懂;存全量等于把噪声也冻进来,
//       外部多返一个无关字段就让 fixture diff 抖一下。
// 2) 抓不到时给【可操作】的报错,而不是一个 stack trace。
//    例:"数据源已 prune / 该 id 太旧,换归档端点或换更近的 id 重试"。
```

抽子集的写法 —— 只留断言要用到的字段,其余一律不存:

```dart
final fixture = {
  'id': id,
  'payload': {                    // ← 只摘解码 / 断言会读的字段
    'messages': raw['messages'],
    'preState': raw['preState'],
    'postState': raw['postState'],
    // …原始响应里其余字段全部丢弃
  },
};
File(outPath).writeAsStringSync(JsonEncoder.withIndent('  ').convert(fixture));
```

**批量抓取脚本**处理"公共 / 限流严的接口"的现实,三个可复制点:

```bash
# tools/fetch_fixtures.sh
ENDPOINTS=( "https://ep1..." "https://ep2..." )   # ① 端点池:轮换用,降低被限概率

next_endpoint() { local ep="${ENDPOINTS[$EP_IDX]}"; EP_IDX=$(((EP_IDX+1)%${#ENDPOINTS[@]})); echo "$ep"; }

call_with_retry() {                               # ② 失败重试,间隔逐次拉长
  local a=1; while [ "$a" -le 3 ]; do
    dart run tools/fetch_cli.dart "$@" "--endpoint=$(next_endpoint)" 2>&1 && return 0
    sleep $((a*15)); a=$((a+1))
  done; return 1
}

out="$ROOT/$src/$(printf '%02d' "$idx").json"
[ -f "$out" ] && { echo "skip $out"; continue; }  # ③ 产物已存在就跳过 = 断点续抓
call_with_retry dump "$id" "--out=$out"; sleep 5   # 每笔之间也 sleep,别打爆数据源
```

三要点连起来:**端点池轮换 + 失败重试拉长间隔 + 产物已存在就跳过(断点续抓)** —— 抓一半被限流 / 网断,重跑脚本能接着抓,已有的不重抓。

**产物布局**:`test/<模块>/fixtures/<来源>/01.json`、`02.json`…… 按来源分目录,每来源几笔,覆盖正常 + 你能想到的脏 / 边界。

---

### 策略 B:手搓字节 fixture(测二进制 / 协议解码,零网络)

**何时用**:被测对象是 **decoder / parser**,吃**字节流**按 layout 解析 —— 自定义二进制格式、protobuf-like、链上事件、蓝牙 / 串口包、文件头。这类**根本不要去抓网络**:直接按协议表把字节拼出来,完全确定,还能造任意边界 / 畸形输入(截断、超界、错位)。

**做法**:一组小工具函数把各类型写成小端字节,用 `BytesBuilder` 按 layout 顺序拼,fixture 类暴露 `toBytes()`。

```dart
// test/<模块>/_fixtures.dart
import 'dart:typed_data';

// 小端编码工具(按协议需要补 i32 / u128 / string 等)
Uint8List _u64Le(BigInt v) {
  final b = ByteData(8);
  b.setUint32(0, (v & BigInt.from(0xFFFFFFFF)).toInt(), Endian.little);
  b.setUint32(4, (v >> 32).toInt(), Endian.little);
  return b.buffer.asUint8List();
}

/// 一个事件的 fixture:构造已知输入字节 → 喂给 decoder → 断言输出
class EventFixture {
  final BigInt amount;
  final bool flag;
  const EventFixture({required this.amount, required this.flag});

  Uint8List toBytes() {
    final b = BytesBuilder();
    b.add(_discriminator);        // [0..8)   事件类型标识
    b.add(_u64Le(amount));        // [8..16)  ← 注释标【字节偏移区间】,对着协议表写
    b.addByte(flag ? 1 : 0);      // [16]     方向 / 标志位
    return b.toBytes();           // padding 不影响解码就不补满
  }
}
```

测试:

```dart
test('decode 正常事件', () {
  final bytes = const EventFixture(amount: BigInt.from(500), flag: true).toBytes();
  final ev = decoder.decode(bytes);
  expect(ev.flag, true);
  expect(ev.amount, BigInt.from(500));
});
```

要点:
- **每个 `add` 后注释字节偏移区间**,对着协议表写 —— 改 layout 时一眼对齐,不抓瞎。
- **一个来源 / 一种协议变体一个 fixture 类**(不同上游格式各一个),覆盖多协议。
- **金额 / 大整数用 `BigInt`,绝不用 `double`** —— `double` 在大数量级会丢精度,断言会假阳 / 假阴。

---

### 策略 C:`forTesting` 工厂注入 mock(测 service 的控制流 + 错误处理)

**何时用**:测一个**依赖外部 IO 的 service**(网络、DB、平台通道)的**控制流和失败处理** —— 不关心 IO 的真实结果,只关心"依赖返回 X / 抛异常 / 超时时,service 怎么反应"。

**做法**:service 暴露 `Xxx.forTesting(call: ...)` 工厂,把外部依赖做成**可注入的函数**;测试用闭包模拟:正常 / 报错 / 抛异常 / 超时 / 空输入。

最值得抄的是**错误处理断言范式** —— 依赖坏了,service 不许崩、不许把内部异常漏给上层,要**收敛成上层能处理的领域内中性状态**(如 `inconclusive`):

```dart
// 正常透传
test('依赖 err=null → ok', () async {
  final s = Service.forTesting(call: (_) async => _ok(data: ['ok']));
  expect((await s.run(input)).status, Status.ok);
});

// ★ 外部抛异常 → 收敛成【中性状态】,不把内部错(StateError)泄露给上层
test('外部抛异常 → inconclusive', () async {
  final s = Service.forTesting(call: (_) => Future.error(StateError('source down')));
  final r = await s.run(input);
  expect(r.status, Status.inconclusive);   // 不是 failed,也不是把异常抛出去
  expect(r.rawErr, isNull);                // 内部错没泄露
});

// ★ 超时也走同一个中性分支
test('超时 → inconclusive', () async {
  final s = Service.forTesting(call: (_) => Completer<R>().future);  // 永远 hang
  expect((await s.run(input, timeout: const Duration(milliseconds: 30))).status,
         Status.inconclusive);
});
```

这层专钉死**健壮性**:"依赖坏了 service 不崩、不漏内部异常、收敛成中性结果" —— 这是真机测试很难稳定复现、却最容易出线上事故的地方。

---

### 策略 D:probe 脚本(一次性探查,不是回归测试)

**何时用**:对"某个数值 / 精度 / 边界在**真实分布**下到底什么样"没把握,想用数据而不是拍脑袋来定实现。

**做法**:写个一次性 `dart run` 脚本,拉真实样本 + 跑统计(median / p90 / p99 / 有效位数),**结论写进代码注释或文档**,脚本留 `tools/` 备查。
例:probe 出"某量级下 `double` 只有 4~6 位有效数字,`toStringAsFixed(12)` 后面全是噪声" → 据此定数值表示与格式化策略。

> **probe ≠ 回归**:probe 是**探查**(回答"现实是什么样"),跑一次拿结论;单测是**回归**(锁住"逻辑必须是什么样"),每次 CI 跑。
> **别把 probe 脚本留在测试套件里当回归用** —— 它依赖真实数据 / 网络,会让套件变慢、变不确定。结论搬进注释后,脚本归 `tools/`。

---

## 4. 第②层:widget test —— 把"上设备点一下"搬到离线

**何时用**:验证**控件交互、页面跳转、表单校验、条件渲染、空/错/加载态**。这些默认容易被划给设备层,但它们绝大多数不依赖真实渲染管线,`testWidgets` 里毫秒级就能证。

**判据(拿这条切分设备层与本层)**:问一句「这件事**必须**要真实的 GPU 渲染 / 真实的系统能力 / 真实的后端数据吗?」

| 答案 | 归属 |
|---|---|
| 不必须(点了之后状态/文案/路由变没变、禁用态对不对、错误提示出没出) | **本层 ②** |
| 必须(真实渲染观感、原生插件/相机/推送、真实网络与账号、平台差异) | 设备层 |

```dart
testWidgets('点提交后跳到首页', (tester) async {
  await tester.pumpWidget(const MyApp());
  await tester.enterText(find.byKey(const Key('email_input')), 'a@b.com');
  await tester.tap(find.byKey(const Key('submit_btn')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('home_screen')), findsOneWidget);
});
```

要点:
- **和 Patrol 共用同一套 `Key`**——SKILL 的代码契约(`Key` + `Semantics` 双标)在这层直接兑现,不用另起一套定位方式。
- `pumpAndSettle()` 跑完所有动画帧;不确定时用它,别手写 `Duration` 等。
- **屏幕尺寸可控**:`tester.view.physicalSize` / `devicePixelRatio` 设成目标机型,配 `addTearDown(tester.view.reset)` 复原——**小屏溢出这类问题在这层就能复现**,不用找真机。
- 网络/存储依赖用第①层的 `forTesting` 注入(策略 C)顶掉,别让 widget test 碰真实 IO。
- **失败信息比设备层好读**:直接给 `found 0 widgets` + 当时的 widget 树,不用截图猜。

---

## 5. 第③层:golden 矩阵 + a11y guideline —— 视觉与契约的机器判定

### 5.1 golden:视觉回归别再靠肉眼看截图

**为什么值得**:靠人/AI 盯整屏截图判断"看起来对不对"既慢又不可靠。golden 给的是**量化数字 + 只画变化区域的图**:

```
Golden "goldens/home_light_x1.0.png": Pixel test failed, 0.32%, 3619px diff detected.
Failure feedback can be found at .../test/failures
```

失败时落**四张产物**,`*_isolatedDiff.png` 是最该看的一张——**只画变化的像素**,一眼定位改了哪块,比读整屏截图省得多:

| 产物 | 是什么 |
|---|---|
| `*_masterImage.png` | 基线 |
| `*_testImage.png` | 本次实际 |
| `*_isolatedDiff.png` | **只有变化区域**(优先 Read 这张) |
| `*_maskedDiff.png` | 变化处叠在实际图上 |

**矩阵化**:一次 `flutter test` 就能跑「主题 × 字号 × 屏幕尺寸」的组合,**几秒钟覆盖手工要跑几十遍的核验**:

```dart
for (final brightness in [Brightness.light, Brightness.dark]) {
  for (final scale in [1.0, 1.5]) {
    testWidgets('golden ${brightness.name}_x$scale', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: MaterialApp(theme: ThemeData(brightness: brightness), home: const HomeScreen()),
      ));
      await tester.pumpAndSettle();
      await expectLater(find.byType(HomeScreen),
          matchesGoldenFile('goldens/home_${brightness.name}_x$scale.png'));
    });
  }
}
```

用法与坑:
- **建基线**:`flutter test --update-goldens`。**基线是要提交进仓库的资产**,和代码一起 review——基线变了就是视觉变了,diff 里看得见。
- **`--update-goldens` 是"接受当前样子"**,不是"修复失败"。失败时**先看 `isolatedDiff` 判断这次变化是不是预期的**,是才更新基线;直接无脑 `--update-goldens` = SKILL 说的「改测试绕过断言」。
- **字体渲染跨机器会有差异**:基线在哪台机器/哪个 CI 镜像生成,就在同类环境比对,否则会出现无意义的整屏 diff。
- 固定 `devicePixelRatio` 和 `physicalSize`,别让默认值随环境漂。

### 5.2 a11y guideline:让"控件天生可测"这条契约自动被拦住

SKILL 的代码契约要求可交互控件包 `Semantics`。这条**不用靠人工自查**——`flutter_test` 自带四条可断言的 guideline,秒级、无设备:

```dart
testWidgets('无障碍契约自检', (tester) async {
  final handle = tester.ensureSemantics();          // 必须先开,结束后 dispose
  await tester.pumpWidget(const HomeScreen());
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));   // 可点控件必须有 label
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));   // 热区 ≥ 48x48
  await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));       // 热区 ≥ 44x44
  await expectLater(tester, meetsGuideline(textContrastGuideline));       // 对比度符合 WCAG
  handle.dispose();
});
```

失败信息直接可操作(实测形态):

```
expected tappable node to have semantic label, but none was found.
  SemanticsNode#6(Rect.fromLTRB(360.0, 320.5, 440.0, 400.5), actions: [tap])

expected tap target size of at least Size(48.0, 48.0), but found Size(20.0, 20.0)

Expected contrast ratio of at least 4.5 but found 1.29 for a font size of 14.0.
```

**为什么这条对本 skill 特别重要**:`labeledTapTargetGuideline` 正好判的就是「没包 `Semantics` 的 `GestureDetector`/`InkWell`」——那是 SKILL 里 `dump ui` 列不出控件的**根因**。加上这条断言后,该问题在离线层就被拦住,**不会等到上了设备才发现"这个控件点不到"**。等于把元素驱动的前提条件变成了 CI 门禁。

> `ensureSemantics()` 只在**测试里**需要;**别为了这个去改 App 代码**——在 App 里调 `SemanticsBinding.instance.ensureSemantics()` 对 `dump ui` 没有任何改善(实测,见 `vm-service.md` §5)。

---

## 6. 目录约定 & 怎么跑

```
tools/
  fetch_cli.dart          # 纯 Dart 抓取 CLI(不依赖 flutter):list / dump 子命令
  fetch_fixtures.sh       # 批量抓取(端点池轮换 + 重试拉长间隔 + 断点续抓)
  probe_*.dart            # 一次性探查脚本(probe,不进回归套件)
test/
  <模块>/_fixtures.dart           # 策略 B:字节 fixture 构造器(toBytes)
  <模块>/fixtures/<来源>/*.json   # 策略 A:真实数据 JSON fixture,按来源分目录
  <模块>/xxx_test.dart            # 用 fixture / forTesting 的单测(策略 A/B/C)
  <模块>/xxx_widget_test.dart     # 第②层:交互/跳转(testWidgets)
  goldens/*.png                   # 第③层:视觉基线,【要提交进仓库】
  failures/                       # golden 失败产物,【加进 .gitignore】
```

跑:
- `flutter test` —— 跑全部(①②③ 一把梭,含需要 flutter binding 的)。
- `dart test` —— 跑**纯 Dart 部分**(不依赖 flutter binding 的解码 / 解析 / 数值),**更快**,优先用于纯逻辑模块。
- `flutter test --update-goldens` —— **只在确认视觉变化符合预期后**才跑(见 §5.1)。

**自主跑时用机读输出,别解析控制台文本**:

```bash
flutter test --reporter json                     # 机器可读的结果流
flutter test --file-reporter json:reports/t.json # 结果落文件,跑完再解析
flutter test --coverage                          # 出 coverage/lcov.info,用来看【哪里还没测到】
```

`--coverage` 在自主循环里的用法:不是为了凑覆盖率数字,而是**回答"我还有哪条分支没验过"**,据此决定下一条测试写什么——比拍脑袋补测试准。

CI 友好:无需设备、确定性、秒级 —— 适合每次 push 都跑,把真机验证留给关键路径 / 夜间。

---

## 7. 硬原则小结

1. **先问"这必须上设备吗"**:交互能 ② 证的别上设备,视觉能 ③ 证的别靠肉眼看截图。真机时间只给离线层够不着的部分。
2. **`--update-goldens` 不是修复手段**:失败先读 `isolatedDiff` 判断变化是否预期,是才更新基线——无脑更新等于改测试绕过断言。
3. **`meetsGuideline(labeledTapTargetGuideline)` 是元素驱动的前置门禁**:让"控件没包 Semantics"在离线层就挂,别等上了设备才发现点不到。
4. **依赖坏了不崩、不漏内部异常**:外部抛异常 / 超时都收敛成领域内中性状态(`inconclusive`),不外泄内部错、不抛、不当 `failed`(策略 C)。
5. **fixture 只抽断言要用的最小字段子集**,不存全量;抓不到给可操作报错(策略 A)。
6. **字节 fixture 每个 add 注释字节偏移区间**,对着协议表写(策略 B)。
7. **金额 / 大整数用 `BigInt`,不用 `double`**(策略 B)。
8. **probe ≠ 回归**:探查脚本拿到结论写进注释,不留在测试套件里(策略 D)。
9. **离线层先全绿再上设备**;`flutter test` 挂 = 逻辑/契约 bug,不上设备直接修。

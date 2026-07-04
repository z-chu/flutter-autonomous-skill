# 离线 / fixture 秒级测试层(下层)

> 本文是 `flutter-autonomous` 的「验证四层」的**第①层**深度展开,术语/原则以 [SKILL.md](../SKILL.md) 为准,不与其矛盾。
> SKILL 已讲清「闭环顺序」「四红线」「自修复≤5轮」「断言失败修实现」等;这里只补 SKILL 没展开的**离线层怎么造数据、怎么注入、放哪、怎么跑**。

---

## 1. 为什么真机之外还要这一层(两层互补)

真机层(元素驱动 + Patrol + 截图)的本质是**集成 + 视觉**:慢、要设备、且**不确定**(联网、外部数据会变、有时序、有动画)。它证明不了、也不该用来证明这类问题:

- "这个解析器吃到脏/畸形数据时输出对不对?"
- "这个依赖外部 IO 的 service,在依赖抛异常 / 超时时会不会崩、会不会把内部错漏给上层?"
- "这段数值计算在某个量级下精度够不够?"

这些都是**纯逻辑**,应该有独立的一层来锁:**离线、确定性、秒级、无设备、CI 友好**。两层各管一段、互补:

| 层 | 锁什么 | 特征 |
|---|---|---|
| **离线 / fixture 层**(本文) | 纯逻辑:解码 / 解析 / 数值 / 状态机 / 错误处理 | 把外部世界冻成确定性输入,秒级、无设备、每次 push 都能跑 |
| **真机 / Patrol 层**(SKILL 主体) | 集成 + 视觉:交互、跳转、渲染、连接、布局 | 需设备、慢、验真机才能验的东西 |

口诀:**能离线证明的逻辑,绝不上真机**。把真机时间留给只有真机能验的集成与视觉。

---

## 2. 闭环里的衔接位

离线层卡在 `flutter analyze` 之后、上设备之前:

```
flutter analyze(零警告)
  → flutter test / dart test   ← 【离线层:本文】秒级、确定性、无设备
        └─ 挂 = 纯逻辑 bug,【不上设备,直接修】
  → 确认设备在线 → 元素驱动(一次性 dump→tap)
  → patrol test(可复跑断言,进 CI)
```

铁律:**离线层全绿才上设备**。`flutter test` 挂着就跑真机,是拿几十分钟的设备时间去定位本可秒级定位的纯逻辑 bug。
`/ship`、`/verify`、`/nightly` 等命令在 `flutter analyze` 之后、`patrol test` 之前,**都先插一步 `flutter test`**。

---

## 3. 四策略(按"被测对象吃什么"选)

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

## 4. 目录约定 & 怎么跑

```
tools/
  fetch_cli.dart          # 纯 Dart 抓取 CLI(不依赖 flutter):list / dump 子命令
  fetch_fixtures.sh       # 批量抓取(端点池轮换 + 重试拉长间隔 + 断点续抓)
  probe_*.dart            # 一次性探查脚本(probe,不进回归套件)
test/
  <模块>/_fixtures.dart           # 策略 B:字节 fixture 构造器(toBytes)
  <模块>/fixtures/<来源>/*.json   # 策略 A:真实数据 JSON fixture,按来源分目录
  <模块>/xxx_test.dart            # 用 fixture / forTesting 的单测(策略 A/B/C)
```

跑:
- `flutter test` —— 跑全部(含需要 flutter binding 的)。
- `dart test` —— 跑**纯 Dart 部分**(不依赖 flutter binding 的解码 / 解析 / 数值),**更快**,优先用于纯逻辑模块。

CI 友好:无需设备、确定性、秒级 —— 适合每次 push 都跑,把真机验证留给关键路径 / 夜间。

---

## 5. 硬原则小结

1. **依赖坏了不崩、不漏内部异常**:外部抛异常 / 超时都收敛成领域内中性状态(`inconclusive`),不外泄内部错、不抛、不当 `failed`(策略 C)。
2. **fixture 只抽断言要用的最小字段子集**,不存全量;抓不到给可操作报错(策略 A)。
3. **字节 fixture 每个 add 注释字节偏移区间**,对着协议表写(策略 B)。
4. **金额 / 大整数用 `BigInt`,不用 `double`**(策略 B)。
5. **probe ≠ 回归**:探查脚本拿到结论写进注释,不留在测试套件里(策略 D)。
6. **离线层先全绿再上设备**;`flutter test` 挂 = 纯逻辑 bug,不上设备直接修。

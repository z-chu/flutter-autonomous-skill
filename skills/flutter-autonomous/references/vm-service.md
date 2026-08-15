# Dart VM Service:从 App 内部取证与控制(第三条路)

> 本文是 keystone(`../SKILL.md`)「核心认知:找控件的三条路」里**第三条**的展开。方法论(元素驱动优先、Key+Semantics 双标、验证分层、收尾回查)以 keystone 为准,这里只讲这条通道**能做什么、怎么调、边界在哪**。
>
> 一句话定位:元素驱动和截图都在 App **外面**看(无障碍树、像素);Patrol 在 App 里面看但**必须写测试文件、必须重新构建**。VM Service 是第三条——**App 正在跑着,不写一行测试、不重新构建,直接从里面把 widget 树、布局尺寸、运行时状态、错误取出来**。`flutter run` 起来的那一刻这条通道就已经开着,只是以前没用。

---

## 1. 三条路的分工(别混用)

| 路 | 看到的是 | 代价 | 什么时候用 |
|---|---|---|---|
| **元素驱动**(`dump ui`) | 系统无障碍树:label + 设备像素 rect | 零(已装 mobilecli) | **要点击/交互**——只有它给可点的坐标 |
| **Patrol** | Dart widget 树,按 `Key` 断言 | 要写测试文件 + 构建一轮 | **要可复跑回归、进 CI** |
| **VM Service**(本文) | Dart widget/render 树、运行时状态、结构化错误 | 零(`flutter run` 已开) | **要诊断/取证/断言,但不需要点** |

关键互补点:**VM Service 不依赖无障碍树**。keystone 说「纯 canvas 绘制两条都找不到 → 回退截图量坐标」——那是**点击**层面的末选;**判断层面**这条路仍然看得见:控件没包 `Semantics`、`dump ui` 列不出,widget 树照样把它列出来,还带源码行号。

> ⚠️ 反过来也成立:**这条路给不了可点坐标**(widget 树里没有设备像素 rect)。要点还是回 `dump ui`。别指望它替代元素驱动。

---

## 2. 开通道:两种入口,优先 `--vmservice-out-file`

### 2.1 拿到 URI(替代 grep stdout)

keystone 的「等构建」是轮询 stdout 等 `Flutter run key commands`。**更可靠的是让 flutter 自己把 URI 写文件**——文件出现即代表 VM Service 已就绪,不用解析人类可读输出:

```bash
flutter run -d <deviceId> --target <entry> \
  --pid-file=<PID_FILE> --vmservice-out-file=<URI_FILE> <dart-defines>
# 另起后台 Bash 等它落盘(文件非空 = VM Service 已起)
until [ -s "<URI_FILE>" ]; do sleep 2; done
```

写进去的是 ws 形式:`ws://127.0.0.1:<port>/<token>/ws`。

### 2.2 转成 HTTP,之后全用 curl

**VM Service 同端口同时接受 HTTP GET**,一条 sed 转出基址,后面所有内省调用都是一行 curl,零依赖:

```bash
VM=$(sed 's|^ws://|http://|; s|/ws$|/|' "<URI_FILE>")     # → http://127.0.0.1:<port>/<token>/
ISO=$(curl -s "${VM}getVM" | jq -r '.result.isolates[0].id')
```

### 2.3 ★ HTTP 与 WS 的能力边界(实测,别踩)

| 走 HTTP GET(curl,零依赖) | 必须走 WebSocket |
|---|---|
| 全部 `ext.flutter.*` 服务扩展 | **`evaluate`**(读/改运行时状态、调函数) |
| `getVM` / `getIsolate` / `getMemoryUsage` | **事件流**(`streamListen` + `Flutter.Error` 结构化错误) |

- HTTP 上调 `evaluate` 会报 `code 113 / "No compilation service available; cannot evaluate from source"`——**这不是命令写错**,是 HTTP 一次性请求拿不到表达式编译服务。同一个 App 换 WS 连上去,`evaluate` 立刻可用。与是否 `--machine` 无关。
- HTTP 是**一次性请求**,天然订阅不了事件流。
- 结论:**内省用 curl,要 evaluate / 要订阅错误事件才起 WS 客户端**(`--machine` 守护协议或 `package:vm_service` / 任意 WS 客户端)。

### 2.4 备选入口:`flutter run --machine`(守护协议)

`--machine` 让 flutter 在 stdin/stdout 上说 JSON-RPC。它多给两样 curl 给不了的东西:

```jsonc
// 调服务扩展(等价于上面的 curl,但走守护进程)
{"id":1,"method":"app.callServiceExtension",
 "params":{"appId":"<appId>","methodName":"ext.flutter.debugDumpApp","params":{}}}

// ★ 热重载,并拿到【结构化成败】
{"id":2,"method":"app.restart","params":{"appId":"<appId>","fullRestart":false,"reason":"edit"}}
// → {"id":2,"result":{"code":0,"message":"Reloaded 0 libraries"}}
```

- `app.started` 事件给 `appId`,`app.debugPort` 事件给 `wsUri`(不用再读文件)。
- **`app.restart` 是 `kill -USR1` 的升级版**:signal 发出去就没了下文,守护协议**返回 code/message**,`code!=0` 直接就是「热重载失败」这条断言,不用去 grep 输出猜。改代码要判成败时用它;只是随手重载用 keystone 的 signal 更省事。

---

## 3. 六条实测配方(照抄可用)

下列命令均已在真机实测通过。`$VM`、`$ISO` 来自 §2.2。

### 3.1 ★ widget 树 + 源码行号(最有价值的一条)

一条 curl 拿到「屏幕上有什么控件、每个是哪行代码画的、Key 是什么」:

```bash
curl -s "${VM}ext.flutter.inspector.getRootWidgetSummaryTree?isolateId=${ISO}&objectGroup=ai" \
 | jq -r '[.result.result] | .. | objects | select(.description? and .createdByLocalProject?)
          | "\(.description)  ←  \(.creationLocation.file | split("/") | last):\(.creationLocation.line)"'
```

实测输出形态:

```
Scaffold-[<'home_screen'>]        ←  main.dart:55
Text-[<'counter_text'>]           ←  main.dart:62
ElevatedButton-[<'inc_btn'>]      ←  main.dart:65
GestureDetector-[<'unlabeled_gesture'>]  ←  main.dart:72
```

要点:
- 参数名是 **`objectGroup`**(不是 `groupName`,写错直接 500 报 `Null check operator used on a null value`)。
- `createdByLocalProject: true` 过滤掉框架自身的节点,只留你的代码。
- **`Key` 直接显示在 description 里**(`-[<'home_screen'>]`)——写 Patrol 用例前用它核对 Key 拼写,比翻代码快,也治 keystone 说的 `found 0 widgets`。
- 这是**当前页面到源码行的直接映射**:截图上看着不对的那块是哪行代码画的,一步定位,不用 grep。

### 3.2 布局实测尺寸与约束(不用肉眼量截图)

```bash
curl -s "${VM}ext.flutter.debugDumpRenderTree?isolateId=${ISO}" | jq -r '.result.data' \
 | grep -E "constraints:|size:"
# → constraints: BoxConstraints(w=411.4, h=820.6)
#   size: Size(411.4, 820.6)
```

布局错位、元素没占满、溢出——**看数字比看截图准**。keystone 的「视觉/布局用截图」仍然对,但**先看这里的数字,截图用来确认观感**。

### 3.3 整棵 widget 树(文本形态)

```bash
curl -s "${VM}ext.flutter.debugDumpApp?isolateId=${ISO}" | jq -r '.result.data'
```

比 §3.1 全但很长(框架节点全在里面),**默认用 §3.1 的结构化版**,只有要看完整嵌套关系时才用这条,且务必截断。

### 3.4 单个部件截图(省 token)

```bash
# id 取 §3.1 结果里的 valueId(如 "inspector-0")
curl -s "${VM}ext.flutter.inspector.screenshot?isolateId=${ISO}&id=<valueId>&width=400&height=800&maxPixelRatio=1.0&debugPaint=true" \
 | jq -r '.result.result' | base64 -d > widget.png     # 实测约 10KB
```

只截**某个部件子树**而不是整屏,`debugPaint=true` 还会画出布局边界。反复核验同一个组件时比整屏截图省得多。

### 3.5 运行时开关(不碰系统设置、不重启)

```bash
curl -s "${VM}ext.flutter.brightnessOverride?isolateId=${ISO}&value=Brightness.dark"   # 切深色模式
curl -s "${VM}ext.flutter.platformOverride?isolateId=${ISO}&value=iOS"                 # 在安卓上看 iOS 观感
curl -s "${VM}ext.flutter.timeDilation?isolateId=${ISO}&timeDilation=1.0"              # 动画时间缩放
curl -s "${VM}ext.flutter.debugPaint?isolateId=${ISO}&enabled=true"                    # 画布局边界
curl -s "${VM}getMemoryUsage?isolateId=${ISO}" | jq -c '.result'                       # 堆占用(泄漏基线)
```

`brightnessOverride` 是深色模式核验的正解:**不改系统设置、不重启 App、不污染设备状态**,切完直接截图对比,收尾也不用还原(重启即失效)。

### 3.6 evaluate:读运行时状态 / 触发动作(需 WS)

断言从「看截图上的数字对不对」变成「直接读那个变量」:

```jsonc
{"jsonrpc":"2.0","id":1,"method":"evaluate",
 "params":{"isolateId":"<iso>","targetId":"<rootLib.id>","expression":"<表达式>"}}
// → result.valueAsString 直接就是值
```

`targetId` 取 `getIsolate` 的 `.result.rootLib.id`,表达式在**根库作用域**里求值。实测可以:读顶层变量、调顶层函数、写顶层变量。

**代码契约配套**:根库作用域看不到 `State` 内部的私有字段。要让这条路能用,给关键状态留一个 **debug-only 出口**——顶层变量或一个注册表,`kDebugMode` 下才维护:

```dart
// 状态出口:供 evaluate 直接读;也可暴露顶层函数供 evaluate 触发动作
int e2eCounter = 0;
final ValueNotifier<bool> e2eFlag = ValueNotifier(false);
String e2eTrigger() { e2eFlag.value = true; return 'ok'; }
```

用途:① 断言状态而不是断言像素 ② **一步把 App 置于某状态**,省掉 N 步导航(比 deeplink 更细,能直接摆内部状态)。

---

## 4. 结构化错误:比 grep 日志硬一档(需 WS)

订阅 `Extension` 流,Flutter 的每个未捕获错误都会以 `Flutter.Error` 事件推过来:

```jsonc
{"jsonrpc":"2.0","id":1,"method":"streamListen","params":{"streamId":"Extension"}}
// 之后收到 streamNotify,event.extensionKind == "Flutter.Error",event.extensionData 形如:
{
  "description": "Exception caught by rendering library",
  "properties": [
    {"description": "A RenderFlex overflowed by 300 pixels on the right."},
    {"description": "The overflowing RenderFlex has an orientation of Axis.horizontal."}
  ],
  "errorsSinceReload": 0,
  "renderedErrorText": "..."
}
```

相对 keystone 现有的 `logcat | grep "RenderFlex overflowed"`:

- **是结构化 JSON,不是正则**——`properties` 逐条给,不用从人类可读文本里抠。
- **`errorsSinceReload` 可直接当断言**:「执行完这步操作,新增错误数必须为 0」是一条比截图硬得多的验收条件,而且**对所有错误类型通用**,不用为每种错误写一条 grep。
- 覆盖面比 grep 宽:溢出、断言失败、build 抛异常,全走这条。

配套开关(HTTP 即可):`curl -s "${VM}ext.flutter.inspector.structuredErrors?isolateId=${ISO}&enabled=true"`。

> **不想起 WS 时的兜底**:错误同样会进平台日志,仍可按 keystone 的 `logcat -s flutter | grep` 抓。`errorsSinceReload` 这条断言则只有 WS 拿得到。

---

## 5. 坑与边界(实测踩过的)

1. **`ext.flutter.debugDumpSemanticsTreeInTraversalOrder` 不是可靠 oracle**。没有无障碍客户端连着时,它返回 `"Semantics not generated for ..."`;有客户端连着时才有树。**判断控件存不存在一律用 widget 树(§3.1),别用这个**。
2. **在 App 里调 `SemanticsBinding.instance.ensureSemantics()` 并不会让 `dump ui` 更稳**。A/B 实测:加与不加,`mobilecli dump ui` 结果完全一致——因为 UI Automator / WDA 本身就是无障碍客户端,一连上 Flutter 就会生成 semantics 树。**别为此改 App 代码**。
3. `getRootWidgetSummaryTree` 的参数是 **`objectGroup`**;写成 `groupName` 会 500。
4. `debugDumpApp` / `debugDumpRenderTree` 返回的是 `{"data": "<很长的文本>"}`,**读之前先 grep/截断**,整块塞进上下文非常浪费。
5. **端口每次 `flutter run` 都变**——`$VM` 必须运行期从 `--vmservice-out-file` 现取,**绝不写进任何文件**(与 keystone「设备 id 绝不写死」同一条原则)。
6. 这条通道**只在 debug/profile 构建存在**,release 包没有。

---

## 6. 什么时候用哪条(决策)

| 你要做的事 | 用哪条 |
|---|---|
| 点一下 / 输入 / 滑动 | 元素驱动 `dump ui` → `io tap`(**只有它能点**) |
| 「这个控件在不在 / 是哪行代码画的」 | **VM Service §3.1**(不依赖 Semantics,还给行号) |
| 「Key 拼对了吗 / 为什么 `found 0 widgets`」 | **VM Service §3.1**(Key 直接显示) |
| 「布局为什么错位 / 尺寸对不对」 | **VM Service §3.2** 看 constraints/size,再截图确认观感 |
| 「这一步操作有没有报错」 | **VM Service §4** `errorsSinceReload`;无 WS 则 logcat grep |
| 「状态机走到哪一步了 / 这个值是多少」 | **VM Service §3.6** evaluate;或 keystone 的日志锚点 |
| 深色模式 / 跨平台观感核验 | **VM Service §3.5** `brightnessOverride` / `platformOverride` |
| 要可复跑、进 CI、出 pass/fail | **Patrol**(这条路不产出可复跑资产) |

> 心法:**要点用元素驱动,要证据用 VM Service,要回归用 Patrol。** 三条不是替代关系,是分工。

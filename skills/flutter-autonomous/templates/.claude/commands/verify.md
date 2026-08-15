---
description: 验证当前改动——按改动类型选最硬证据，先离线后设备跑分层闭环，失败分类自修复 ≤5 轮
allowed-tools: Bash(flutter:*), Bash(flutter run:*), Bash(dart:*), Bash(patrol:*), Bash(adb:*), Bash(xcrun:*), Bash(kill:*), Bash(ps:*), Bash(mobilecli:*), Bash(npx mobilecli:*), Bash(bash scripts/tap-by-label.sh:*), Read, Edit, Write, Grep, Glob
argument-hint: [验证用例文件路径（可选，不填则跑 integration_test/ 全部）]
---

对当前改动做验证。规则、定位优先级、Key+Semantics 双标、收尾两步全部对齐 `flutter-autonomous` skill，本命令只走流程不复述方法论。

## 第 0 步：按改动类型选「最硬证据」

不是所有改动都要上设备——**先问「这必须上设备吗」，再选证据**：

| 改动类型 | 最硬证据 | 要设备吗 |
|---------|---------|---|
| 纯逻辑（解析 / 数值 / 状态机 / 错误处理） | **离线 fixture**：`flutter test`，秒级 | 否 |
| 控件交互 / 页面跳转 / 表单校验 / 条件渲染 | **widget test**：`testWidgets` + `tester.tap` + 按 `Key` 断言 | **否**（这条最容易被误判成要设备） |
| 视觉 / 布局 / 颜色 / 深色模式 / 大字号 | **golden 矩阵**：`matchesGoldenFile`，出量化 diff + 只画变化区域的图 | 否 |
| 可交互控件有没有 label / 热区 / 对比度 | **a11y guideline**：`meetsGuideline(labeledTapTargetGuideline)` 等 | 否 |
| 控件找不到 / Key 对不对 / 布局真实尺寸 / 这步报没报错 | **VM Service**：一行 curl 取 widget 树（带源码行号）、render 树、`errorsSinceReload` | 是（但不用点） |
| WebSocket / RPC 连接、状态机切换、gating 逻辑 | **日志**：清缓冲 → 执行动作 → 只读这一步的日志窗口再断言 | 是 |
| 真机渲染观感 / 系统集成 / 真实数据 | **元素驱动 + 截图**：`dump ui`→点 rect 中心，或 `bash scripts/tap-by-label.sh <id> "<label>"` | 是 |
| 需要精确、可复跑、进 CI 的断言 | **Patrol**：按 `Key`，出 pass/fail | 是 |

混合改动就组合用。**别为了跑而跑 Patrol，也别把离线层能证的事搬上设备。**

---

## 第 1 步：分层闭环（顺序固定，离线层全绿才上设备）

```bash
# ① 静态：零警告才继续
flutter analyze

# ② 离线层（秒级，无设备）——纯逻辑 + widget test + golden/a11y 一把跑完
#    这里失败 = 逻辑 / 行为 / 视觉契约 bug，不上设备，直接按「失败分类 C」修实现。
flutter test                 # 无 test/ 目录时跳过此步

# ③ 设备发现（绝不写死 id；iOS 默认目标模拟器，细节见 references/ios.md）
mobilecli devices            # 空再退 adb devices / xcrun simctl list devices booted
```

- analyze 有警告 / 离线层失败：**先修再继续**，离线层全绿才上设备。
- golden 失败先读 `test/failures/*_isolatedDiff.png`（只画变化区域）判断这次视觉变化是否预期；**是预期才 `flutter test --update-goldens`**，无脑更新 = 改测试绕过断言。
- 设备都空：按 skill 的环境自举自救一次（`adb kill-server && adb start-server` / `xcrun simctl boot <udid>`）；仍空=设备物理掉线，**停止，输出「设备离线」报告，不进循环**。

进设备前先确认前台是目标包，防串台：`mobilecli apps foreground --device <id>`。

```bash
# ④ 设备层（按第 0 步选的证据执行其一或组合）
# 4a 元素驱动（一次性交互/跳转/展示）
bash scripts/tap-by-label.sh <deviceId> "<label子串>"        # 或手动 dump ui→io tap rect 中心
mobilecli screenshot --device <deviceId> -o <out>           # 截图 → Read 核验

# 4b Patrol（精确、可复跑回归）——$ARGUMENTS 有路径跑指定文件，否则全量
patrol test -t $ARGUMENTS --device <deviceId>               # 不填路径则省去 -t
```

---

## 第 2 步：失败分类自修复（≤5 轮）

**断言失败=逻辑 bug，修实现，绝不改测试降标准。** 第 3 轮记下已试方向，第 4 轮换思路，第 5 轮停下出卡住报告。

- **A 编译 / 构建失败**：读**完整** `flutter analyze` 输出（不只看末行），修代码，回第 1 步。构建反复失败 `flutter clean && flutter pub get` 再来。
- **B `found 0 widgets`**：**先用 VM Service 把当前 widget 树拉出来核对**（带 `Key` 和源码行号，比翻代码快）：
  ```bash
  VM=$(sed 's|^ws://|http://|; s|/ws$|/|' <URI_FILE>); ISO=$(curl -s "${VM}getVM" | jq -r '.result.isolates[0].id')
  curl -s "${VM}ext.flutter.inspector.getRootWidgetSummaryTree?isolateId=${ISO}&objectGroup=ai" \
   | jq -r '[.result.result] | .. | objects | select(.description? and .createdByLocalProject?)
            | "\(.description)  ←  \(.creationLocation.file | split("/") | last):\(.creationLocation.line)"'
  ```
  再查 `Key` 拼写 → 条件渲染（`isLoading?`/`isVisible?`）→ 是否要先 `.scrollTo()`。控件 `dump ui` 列不出 = 没暴露 Semantics，**回代码补 `Semantics(label:)`** 并补一条 `meetsGuideline(labeledTapTargetGuideline)` 让它以后自动被拦住，别将就盲点。
- **C 断言失败（expect 不符）**：逻辑 bug，读实现修，**不降断言标准**。
- **D crash / 超时**：`mobilecli device crashes list --device <id>` → `... crashes get <crash_id> --device <id>`，读堆栈第一个 `package:<your_app>/` 的行，修那段。
- **E 安装 / 断连**：`mobilecli devices` 确认状态，重试一次仍失败则停止报告。

**第 5 轮仍未通过**：
```
⚠️ 验证失败（已尝试 5 轮）
失败的断言/现象：<具体>
错误原文：<原始信息>
已尝试方向：1. ... 2. ...
判断：<根因推测 + 需人工决策的点>
```

---

## 第 3 步：通过后取证 + 收尾

- 视觉类改动：`mobilecli screenshot` 截图 Read 核验布局/截断/颜色/空态/Loading。
- **收尾两步并回查**（`kill flutter run` ≠ 关 App）：
```bash
kill "$(cat <PID_FILE>)" 2>/dev/null                       # 停 flutter run 宿主
mobilecli apps terminate --device <id> <packageName>       # 真关 App（抹平 Android/iOS）
mobilecli apps foreground --device <id>                    # 回查：确认前台已不是目标 App
```
**宣布「验过 / 关好」前必须用独立命令回查真实状态**，不拿「执行了 kill」当「App 关了」。

---

## 最终报告

```
## 验证结果：✅ 全绿 / ❌ 部分失败

### 用的证据
- 连接/状态机 → 日志：<grep 命中>
- 交互/跳转 → 元素驱动 / Patrol
- 视觉 → 截图

### 验收条件
- [x] 条件1
- [ ] 条件3（失败说明）

### 改动
- lib/xxx.dart：原因
- integration_test/xxx_test.dart：原因

### 截图
（关键截图）

### 遗留（需人工决策）
无 / <具体内容>
```

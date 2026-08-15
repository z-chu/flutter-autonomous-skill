---
description: 分析 crash / 测试失败，并行收证→按类型定位根因→修实现→验证→输出根因报告
allowed-tools: Bash(flutter:*), Bash(flutter run:*), Bash(dart:*), Bash(patrol:*), Bash(adb:*), Bash(xcrun:*), Bash(ps:*), Bash(mobilecli:*), Bash(npx mobilecli:*), Read, Edit, Grep, Glob
argument-hint: [失败描述 / crash 信息（可选，不填则分析最近一次失败）]
---

**调试目标**：$ARGUMENTS（没提供则分析当前状态的最近一次失败）

规则、定位优先级、失败分类全部对齐 `flutter-autonomous` skill。本命令侧重「定位根因」，可改实现修复，**没有 Write 权限**——新建文件请走 `/ship`。

---

## 第 1 步：并行收证

无依赖，**同一批一起发**（设备发现不写死 id；iOS 日志走 `xcrun simctl spawn`，见 references/ios.md）：

```bash
# App 运行时日志（连接/状态机/异常栈最硬的证据）
flutter logs 2>&1 | tail -120
adb logcat -s flutter -d 2>&1 | tail -120                       # Android；先认目标 App PID 防串台

# Crash 报告
mobilecli devices                                               # 拿在线设备 id
mobilecli device crashes list --device <id>
# 有 crash 再拉详情：mobilecli device crashes get <crash_id> --device <id>

# 静态分析（编译类失败的根因常在这）
flutter analyze 2>&1 | tail -60
```

---

## 第 2 步：按类型定位根因

- **Crash**：在堆栈里找**第一个 `package:<your_app>/` 的行**——那就是 crash 的代码位置，读那段。系统/框架帧往下跳过。
- **断言失败**：比对「测试期望的状态」vs「实现实际产生的状态」，找逻辑差异点。
- **`found 0 widgets`**：查 `Key` 拼写（大小写/下划线）→ 查条件渲染逻辑 → 查控件是否在视口外（需 `scrollTo`）→ 若控件根本没暴露 `Semantics` 则 `dump ui` 也列不出，定位为代码缺 `Semantics`。
- **编译错误**：读**完整**错误信息（不只末行），常是类型/import/缺参数。

定位手段优先元素驱动与日志：`mobilecli dump ui --device <id>` 看控件实际有没有暴露、label 是什么；`mobilecli screenshot` 看当时屏幕状态。

---

## 第 3 步：修复

- **修实现，不改测试来绕过失败**（断言失败=逻辑 bug）。
- 仅当确认是用例本身写错（Key 名拼错、漏 `pumpAndSettle`）才改测试——且要先排除实现问题。

---

## 第 4 步：验证修复

```bash
flutter analyze                                                 # 无新错误
patrol test -t <相关测试文件> --device <id>                      # 复跑确认通过；iOS 默认模拟器
```

---

## 输出根因报告

```
## 调试报告

根因：<一句话，是什么问题>
位置：<文件:行号>
原因分析：<为什么会发生>
修复内容：
- <文件>：改动说明
验证：<重跑 analyze / patrol 的结果>
遗留：无 / <需人工决策的点>
```

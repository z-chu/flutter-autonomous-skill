---
description: 全自主交付单个功能：定标准 → 实现 → 四层验证 → 修复 → 截图 →（按用户提交策略处理提交）
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
argument-hint: [一句话需求，包含「完成的样子」]
---

需求：$ARGUMENTS

**全程自主执行。** 可逆低风险（装工具 / 改本地配置 / 补依赖 / scaffold 测试）自己做完接着干；只有触到四红线（设备物理掉线 / 真金链上交易 / 私钥密钥操作 / 不可逆破坏）或需求有无法自决的歧义时才停下。规则、定位优先级、Key+Semantics 双标、热重载档位、收尾两步全部对齐 `flutter-autonomous` skill，本命令只走流程。**提交不是默认动作**——按用户提交策略处理（见第 5 步）。

---

## 第 1 步：定验收标准（自己确认，不等人）

展开 3~8 条可断言验收条件：每条「操作（找 `Key`/label → 做什么）→ 预期」；列出要新增的 `Key`+`Semantics` 控件清单；列出要改的文件；标清每条该落哪层验证（离线 fixture / 设备 / 日志取证）。

需求本身有无法自决的歧义（不知跳哪页、UI 不明确、平台不明确）→ **停下说明歧义点，等我确认**。

---

## 第 2 步：实现

- 写 Dart 实现，遵守项目 `CLAUDE.md` 全部约定。
- 关键控件加 `key: const Key('xxx')`（Patrol 用）+ `Semantics(label:)`（元素驱动用）；自定义手势控件显式包 `Semantics(label+button:true)`。
- 同步配套测试：可离线锁的纯逻辑写 `test/.../xxx_test.dart`（fixture/mock）；交互/跳转/展示写 `integration_test/<feature>_test.dart`（验收条件逐条转 Patrol 用例，按 `Key`）。
- 改代码靠 `--pid-file` + `USR1`(方法体热重载) / `USR2`(初始化·main·路由热重启)，别动不动冷启。

---

## 第 3 步：四层验证（顺序固定，≤5 轮自修复）

每轮：

```bash
flutter analyze                       # ① 零警告才继续
flutter test                          # ② 离线 fixture 层（秒级，无设备；无 test/ 跳过）——先绿再上设备
mobilecli devices                     # ③ 设备发现（不写死 id；iOS 默认模拟器，见 references/ios.md）
mobilecli apps foreground --device <id>   # 进设备前确认前台=目标包，防串台
patrol test -t integration_test/<feature>_test.dart --device <deviceId>   # ④ 设备层：Patrol 按 Key
```

- 离线层（②）失败 = 纯逻辑 bug，按下方分类 C 修实现、**不降断言**，离线全绿才上设备。
- 设备都空：环境自举自救一次仍空 = 离线，停止报告。
- **失败分类**（断言失败=改实现不改测试）：
  - A 编译失败 → 读完整 analyze 输出修，回轮首
  - B `found 0 widgets` → 查 Key 拼写 / 条件渲染 / 需否 `.scrollTo()`；列不出=回代码补 `Semantics`
  - C 断言失败 → 逻辑 bug，修实现，不降标准
  - D crash/超时 → `mobilecli device crashes list/get` 读堆栈首个 `package:<your_app>/` 行
  - E 安装/断连 → `mobilecli devices` 重试一次仍败则停
- **第 5 轮仍未通过**：停止本功能，输出卡住报告（失败现象 / 错误原文 / 已试方向 / 根因推测）。

---

## 第 4 步：截图核验

`mobilecli screenshot --device <id> -o <out>` → Read 自检布局/截断/颜色/空态/Loading。视觉问题改代码即可，不必重跑 Patrol（除非视觉修复动了功能逻辑）。

---

## 第 5 步：收尾 +（按提交策略）处理提交

```bash
# 收尾两步并回查（kill flutter run ≠ 关 App）——这步永远要做
kill "$(cat <PID_FILE>)" 2>/dev/null
mobilecli apps terminate --device <id> <packageName>
mobilecli apps foreground --device <id>            # 回查确认已关
```

**提交不是本流程默认动作**：按用户的提交策略处理（开工前问清 / 见项目 `CLAUDE.md` 的 `{{COMMIT_POLICY}}`）——增量提 / 干完再统一提 / 不提（人工自己提）/ 其它。**不默认自动提交。** 若策略要提交，规范以用户全局 / 项目 `CLAUDE.md` 为准（精确 `git add` 不用 `git add .`、约定式 message、含反引号/`$`/`!` 用单引号或 `-F`、绝不加 AI 署名、是否 push 看策略），提交后 `git log -1 --stat` 回查 HEAD 确实动了。

---

## 第 6 步：报告

```
## ✅ 功能：<功能名>

验收条件：
- [x] 条件1
- [x] 条件2

改动：lib/xxx.dart, integration_test/xxx_test.dart, test/xxx_test.dart
验证：analyze ✅ / flutter test ✅(N) / patrol ✅(N) / 截图 ✅
Commit：（若按策略提交了）<hash> feat: xxx（已回查 HEAD）/ 否则注明「按策略不提交」
截图：（关键截图）
遗留：无 / <具体>
```

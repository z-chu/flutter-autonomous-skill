# {{APP_NAME}} — 项目宪法（真机/自动化测试落地清单）

> 真机运行/自动化测试方法论见全局 `flutter-autonomous` skill，本文件只放本项目特定值与落地清单。
> 不复述工具矩阵 / 元素驱动 / 验证分层 / 6 条约定——那些在 skill 里，这里改了反而会和 skill 矛盾。

---

## 项目信息（占位，用 `{{...}}` 便于 `sed` 批量替换）

| 键 | 值 | 来源/说明 |
|---|---|---|
| 应用名 | `{{APP_NAME}}` | |
| Android applicationId | `{{ANDROID_APPLICATION_ID}}` | 同 `android/app/build.gradle(.kts)` 的 `applicationId`；用于 `apps launch/foreground/terminate` |
| iOS Bundle ID | `{{IOS_BUNDLE_ID}}` | 同 `ios/Runner.xcodeproj/project.pbxproj` 的 `PRODUCT_BUNDLE_IDENTIFIER` |
| Dart 包名 | `{{DART_PACKAGE}}` | `pubspec.yaml` 的 `name:`；Patrol/import 写 `package:{{DART_PACKAGE}}/...`；crash 堆栈认这一行 |
| 入口 | `{{ENTRY_POINT}}` | 默认 `lib/main.dart`；`flutter run --target` / Patrol 用 |
| dart-defines | `{{DART_DEFINES}}` | 形如 `--dart-define=APP_ENV=debug`；无则留空、删命令里的对应行 |
| env 文件 | `{{ENV_FILE}}` | 形如 `.env.json`，配 `--dart-define-from-file`；无则删 |
| pid-file | `{{PID_FILE}}` | 默认 `/tmp/flutter_app.pid`；多设备/多会话并发时拼项目或设备后缀避免撞 |

> 缺哪一项就照 skill「开工先收集上下文」自动探测补全，**别写死，别问人**。

---

## 设备（运行时动态取，绝不写死）

设备 id **不进任何文件**——每次运行期现取：

```bash
mobilecli devices            # 首选，跨 iOS/Android 统一；取 .data.devices[0].id 或按 name 过滤
flutter devices              # 兜底；含模拟器/真机
# Android 兜底 adb devices；iOS 模拟器 xcrun simctl list devices booted
```

**优先真机**，真机离线再退模拟器并在报告里注明。物理分辨率同样运行时取（`mobilecli` / `dump ui` 返回的 rect 已是设备物理像素，**直接用、无需换算**；只有截图量坐标才需换算）。如确需固定填，留这里选填：

```
{{DEVICE_RESOLUTION}}        # 选填，如 Android 1080x2400 / iOS 1179x2556；留空=运行时取
```

---

## 日志锚点（grep 这些验证功能，比截图硬）

`{{LOG_ANCHORS}}` —— 填本项目特有关键字，验「连接/状态机/关键流程」时 grep：

```
# WS/长连接 建立：   {{LOG_ANCHORS}}
# WS/长连接 断开：   {{LOG_ANCHORS}}
# 状态切换：         {{LOG_ANCHORS}}
# 关键业务流程：     {{LOG_ANCHORS}}
# 布局溢出（通用）： RenderFlex overflowed   ← 带 file:line，定位 overflow
```

抓法（平台细节见 skill 的 `references/{android,ios}.md`）：`adb logcat -s flutter -d | tail -200`（Android）/ `flutter logs`（通用）/ iOS 模拟器 `xcrun simctl spawn <udid> log stream`。同设备多个 Flutter App 的 `I/flutter` 都进 logcat，**先认目标 App PID** 再读。

**断言时把日志切成窗口**（清缓冲 → 执行一个动作 → 只读这一步的日志），否则分不清是这一步产生的还是上一步残留的——见 skill `references/android.md` §4.1。App 侧建议打**单行 JSON 锚点**（`dev.log('{"evt":"...","...":...}', name: 'e2e')`），断言用 `jq` 而不是正则猜文本。错误类断言更硬的做法是 VM Service 的 `errorsSinceReload`（`references/vm-service.md` §4），一次覆盖所有错误类型。

---

## 工具链约束

`{{TOOLCHAIN}}` —— 本项目对构建工具版本的硬要求（不满足会构建失败/签名失败）：

```
JDK：     {{TOOLCHAIN}}    # 如 JDK17，Gradle 与 AGP 绑定的版本
Xcode：   {{TOOLCHAIN}}    # iOS 最低 Xcode / CLT 版本
Gradle：  {{TOOLCHAIN}}    # 如 wrapper 锁定版本
其他：    {{TOOLCHAIN}}    # NDK / CocoaPods / Flutter channel 等
```

---

## 同设备共存 App（防串台 / 收尾用）

`{{COEXISTING_APP_IDS}}` —— 同一台设备上长期共存的**别项目**包名（applicationId/bundleId 不同、互不覆盖）。
作用：①截图/点击前确认前台不是它们；②收尾时这些残留 App 也一并 `apps terminate`，回查前台不是残留：

```
{{COEXISTING_APP_IDS}}       # 如 com.other.app, com.demo.sandbox；无则填「无」
```

---

## 敏感数据（截图脱敏，选填）

`{{SENSITIVE_DATA_NOTE}}` —— 若真机/账号含敏感信息（余额、私密内容、个人身份等），在此写脱敏要求：截图前打码/切到脱敏环境/不入库。无敏感数据填「无」。

```
{{SENSITIVE_DATA_NOTE}}
```

---

## 本项目不可逆 / 红线（默认禁止，不自作主张）

`{{IRREVERSIBLE_REDLINES}}` —— skill 四红线（设备物理掉线 / 花真钱的操作 / 密钥凭证 / 不可逆破坏）之外，**本项目特有**的红线动作。红线默认一律不做：交互会话可停下问一句；无人值守跳过该项、报告标注「需授权」后继续：

```
{{IRREVERSIBLE_REDLINES}}    # 按项目形态填。电商如：真实下单/支付/退款；社交如：向真实用户发消息/发布内容；区块链如：上链交易/触碰私钥助记词；通用如：改生产配置/删用户数据
```

### 红线授权例外（默认全禁，在这里写明才可做）

`{{AUTHORIZED_REDLINE_EXCEPTIONS}}` —— 红线类操作（花真钱 / 密钥凭证 / 不可逆）**默认一律不做**；仅当你在这里（或本次指令里）明确写了允许，AI 才会执行对应操作，且只做写明的范围：

```
{{AUTHORIZED_REDLINE_EXCEPTIONS}}   # 如：「沙箱环境可真实下单/支付」「测试链(devnet)可发交易」「可清空测试账号数据」；全禁就填「无」
```

---

## 完成定义（DoD）——离线层是第一关

按顺序逐关过，**前一关不绿不进下一关**（省设备时间）：

1. [ ] **离线层全绿**：`flutter test` —— 一条命令跑完三样，**都不需要设备**：
       - 纯逻辑（解析/数值/状态机/错误处理）用 fixture+mock
       - 交互/跳转/表单/条件渲染用 `testWidgets`
       - 视觉用 golden 矩阵（主题×字号）、无障碍契约用 `meetsGuideline`
2. [ ] **静态零警告**：`flutter analyze` 零 error / 零 warning
3. [ ] **目标设备 Patrol 全绿**：`patrol test -t integration_test/<feature>_test.dart --device <运行时取的 id>`
4. [ ] **截图视觉确认**：`mobilecli screenshot` 后 Read 核验，无溢出/错位/空白（golden 已覆盖的不必重复肉眼看）
5. [ ] **按提交策略处理**（见下「提交策略」`{{COMMIT_POLICY}}`：增量提 / 最后提 / 不提——选「不提」则跳过此关）

> **先问「这必须上设备吗」**：能离线证明的逻辑、交互、视觉都别上真机；能用日志（连接/状态机）证明的别只靠截图；控件找不到/布局不对先查 VM Service 的 widget 树（带源码行号）再截图。分层细节见 skill「验证分层」与 `references/vm-service.md`。

---

## 提交策略（由你定，skill 不替你决定、不默认自动提交）

`{{COMMIT_POLICY}}` —— 填本项目希望 AI 怎么提交，AI 开工前按这条执行（没填会先问一句）：

```
{{COMMIT_POLICY}}    # 选一/自定义：① 干一点提交一点 ② 干完再统一提 ③ 不提交（只改不提，人工自己提） ④ 其它要求
```

若选「提交」，提交规范（约定式前缀 feat/fix、精确 `git add <文件>` 不 `git add .`、是否 push、message 含反引号 / `$` / `!` 用单引号或 `-F`、**绝不加 AI 署名**）沿用全局 `CLAUDE.md` 或在此覆盖。

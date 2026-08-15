# 受限网络 / 受限权限下的自举

> keystone(`../SKILL.md`)§2 的展开。**只给方向,不写菜谱**——命令你自己会写,这里只放你猜不到、猜错要多花几轮的那几件事。

---

## 判据:渠道 还是 权限

- **渠道问题**(包管理源被挡):**仍在绿区**,换条路继续。绿区看的是「目标」不是「渠道」,一条路不通 ≠ 做不到。
- **权限问题**(只有人在 GUI 里能给——macOS 辅助功能报 `-1719`、设备「允许 USB 调试」、iOS 开发者模式、`xcode-select --install` 弹窗):**真停**,和设备物理掉线同级。交互会话问一句;无人值守跳过该项、报告标注「需人工授权:在哪点什么」,继续下个任务。

判反的代价不对称:渠道当权限 → 白停一轮(本可自己绕);权限当渠道 → 在死路上耗光自修复轮次。**一条 `curl` 探一下比猜便宜。**

---

## npm 被拦时,你猜不到的几件事

> `bash scripts/bootstrap.sh` 已自动处理 mobilecli 和 jq(npm/brew 不通就转 GitHub Releases)。下面只在**脚本也报两条渠道都不通**时才需要。

1. **`npx` 不是回退方案**——它和 `npm i -g` 走同一个 registry,npm 被拦它必然一起被拦。源码 `make build` 要 Go 工具链,在没装 Go 的机器上同样是死路。这两条最容易白试。
2. **报错里出现公司网关域名、或响应体是 HTML 拦截页 = 网络策略**,不是你能配掉的。别在 `NODE_OPTIONS=--use-system-ca`、换 registry、关 `strict-ssl` 上耗轮次——直接换渠道。
3. **能从 GitHub Releases 救的**:`mobile-next/mobilecli`(zip)、`jqlang/jq`(裸静态二进制,不用解压)。取地址时**在真实资产列表里按平台关键字匹配,别拼文件名**——上游改命名(加 `v` 前缀、换 `darwin`/`amd64` 写法)拼接那条就断了。`api.github.com` 未认证有速率限制(超了 403),而 `releases/latest` 的重定向能拿到 tag 且不受限,可作兜底。
4. **救不了、也别耗的**:mobile-mcp / mobilewright 是 npm 包,release 无资产、clone 下来仍要 `npm install` 拉依赖——mobilecli 已覆盖交互底座,而且改 MCP 配置本来就要下次会话才生效。**patrol_cli 在 pub.dev,那是和 npm 相互独立的通道**,npm 被拦不代表它被拦,先直接试 `dart pub global activate patrol_cli` 再说。
5. **mac 上下完仍 `permission denied`**:除了 `chmod +x`,还要 `xattr -d com.apple.quarantine`——`curl` 下来的可执行文件都带 Gatekeeper 隔离属性,这一步漏了会以为是没装好。
6. **PATH 不跨 Bash 调用留存**:装进 `~/.local/bin` 之后,后续**每一条**命令都要自带 `export PATH="$HOME/.local/bin:$PATH";` 前缀。想一劳永逸就装到已在 PATH 的目录,或写进 shell rc——但**改用户 shell rc 属于改用户环境,先问一句**。

> **范围**:本文只管**包管理源被拦**(现实里就是 npm 这类)。Xcode / Android SDK / adb / Google 与 Apple 的分发域名**不在考虑范围**——公司真拦这些,他们自己的开发也没法干活了。

---

## 某层被卡住:降级,别整轮停

保留还能跑的层,并在报告里写明**哪层被什么卡住、卡住的是渠道还是权限**:

- 设备交互装不上 → 离线层照跑(`flutter test`,不需要设备也不需要网络,断言覆盖往往比你以为的高)。
- Patrol 装不上 → 元素驱动 + 截图先把功能证到位,回归用例等渠道通了再补。
- 某个手势打不进去(如 WDA 合成的长按 Flutter 侧不认)→ **优先改代码让它可测**(换成有 `Semantics` 的可点控件),这和 keystone「列不出=回代码补」是同一条原则,顺带人工测试也更好用。

别把"环境不允许"写成"已验证",也别因为一层跑不成就整轮停下。

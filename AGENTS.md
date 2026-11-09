# 提交规范

Git 提交信息必须以直接书写的 gitmoji emoji 开头（例如 `🎉 Initialize project`），不要使用 `:tada:` 这样的短代码。提交描述保持简短，最多一句话，不罗列内容，不添加提交正文。

# 依赖

Linux 上只依赖 FoundationEssentials，不引入完整的 Foundation：完整 Foundation 会把 ICU 静态链接进二进制（约 44 MiB），而项目不需要国际化。需要 Foundation 类型时写成 `#if canImport(FoundationEssentials) import FoundationEssentials #else import Foundation #endif`；新增依赖前确认它在 Linux 上不会 import 完整 Foundation（Hummingbird 以 `traits: []` 引入就是为此）。改动依赖后，用 `nm` 检查 release 二进制里没有 `icudt` 符号。

# 控制面板

界面文字用英文写在 `Sources/UnladenServer/Panel/panel.html`/`panel.js` 里；新增或修改界面文字时，同时在 `Panel/i18n.js` 里补上中文对照（带变量的句子用正则条目）。

# 密钥

不要把看起来像密钥的字面量（例如公开的 OAuth client secret）明文写进源码，GitHub 的推送保护会拦下。确实需要内置时，像 `AntigravitySignIn` 那样存成倒序的 Base64，运行时解码。

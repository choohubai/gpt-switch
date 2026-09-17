# GPT Switch

独立的 macOS 启动器，可在模型配置面板中添加模型 ID 和窗口大小（单位 k），通过 CDP 注入 ChatGPT/Codex 的 renderer，并把自定义模型写入 Codex 模型目录。用户选中后，客户端按该模型 ID 发起请求。

## 它做了什么

- 模型配置填写 `id` 和窗口（k），新增行默认 272k；界面显示和实际请求均使用该模型 ID。
- 插件启动时不启动或重启 ChatGPT/Codex；点击面板中的“保存并重启 ChatGPT”后，启用一个仅监听 `127.0.0.1` 的随机 Chromium 调试端口并应用配置。
- 通过 CDP 在 renderer 运行时补充 Statsig 白名单和模型列表响应，这部分注入只存在于当前 renderer 会话，重启后失效。
- 保存模型时会把自定义模型合并进 Codex 模型目录：默认写入 `~/.codex/model_catalog.json`，并在 `~/.codex/config.toml` 中补上 `model_catalog_json` 配置。该目录是磁盘文件，由 Codex 自己读取，所以插件退出或删除后，已保存的自定义模型仍然保留。
- 点击“清空并重启”会删除插件保存的模型配置，并清理插件写入的模型目录和 `model_catalog_json` 配置，然后重启 ChatGPT/Codex。
- 插件启动后在 macOS 菜单栏显示应用图标，菜单提供“打开面板”和“退出”。
- 面板底部显示当前版本并提供“检查更新”：检测到新版本时，可直接打开对应 GitHub Release 下载页。

它不会修改 `ChatGPT.app`、`Codex.app`、`app.asar`、代码签名、API 密钥或历史会话；但会写入 `~/.codex/config.toml` 和 `~/.codex/model_catalog.json`。

## 赞助商

<p align="center">
  <a href="https://choohub.net">
    <img src="docs/images/choo-hub.png" alt="ChooHub" height="110">
  </a>
</p>
<p align="center">
  <a href="https://choohub.net/"><strong>统一 AI 网关，稳定转发调用</strong></a><br>
  ChooHub 为开发者提供统一的 AI 模型接入服务，通过一套配置即可在 ChatGPT/Codex 工作流中灵活切换所需模型，减少重复接入和环境维护成本，适合个人开发、团队协作与长期项目使用。
</p>


## 使用方法

请从 [GitHub Releases](https://github.com/choohubai/gpt-switch/releases) 下载最新版本的 DMG，双击打开后将 `GPT Switch.app` 拖入“应用程序”文件夹。

1. 确认 Codex 桌面端已经安装在 `/Applications/ChatGPT.app` 或 `/Applications/Codex.app`。
2. 双击 `GPT Switch.app`，点击菜单栏图标，选择“打开面板”。
3. 添加模型 ID 和窗口（k），点击“保存并重启 ChatGPT”，然后新建任务并打开模型选择器。
4. 需要移除全部自定义模型时，点击“清空并重启”，插件会清理配置和模型目录并重启 ChatGPT/Codex。
5. 需要停止插件时，点击 macOS 菜单栏中的插件图标，选择“退出”。

### 模型配置

点击菜单栏图标，选择“打开面板”，编辑模型 ID 和窗口（k）；使用加号添加模型，减号删除选中的模型。

- “保存”：保存配置并更新 Codex 模型目录；当前已打开的模型菜单需要重启 ChatGPT/Codex 后才会刷新。
- “保存并重启 ChatGPT”：先保存配置，再重启 ChatGPT 并应用模型列表。
- “清空并重启”：删除本插件保存的模型配置，清理插件写入的模型目录和 `model_catalog_json` 配置，然后重启 ChatGPT/Codex。若 `model_catalog_json` 在安装插件前就已存在，则保留该配置和文件，只把自定义模型从目录中移除。

配置保存在 `~/Library/Application Support/GPTSwitch/models.json`，属于本插件。首次使用时模型列表为空，请在面板中自行添加；升级插件不会覆盖已保存的配置。删除全部模型并点击“保存并重启 ChatGPT”后，自定义模型会从模型目录中移除，但目录文件和 `model_catalog_json` 配置仍在；要一并清理，请点击“清空并重启”。

从 0.1.27 起插件更名为 GPT Switch（原 CodexModelUnlocker）：首次启动会把旧配置目录 `~/Library/Application Support/CodexModelUnlocker/models.json` 自动复制到新目录，无需手动迁移。

首次打开如果被 macOS 拦截：

1. 打开“系统设置”。
2. 进入“隐私与安全性”。
3. 往下滚动到“安全性”区域。
4. 找到“GPT Switch.app 已被阻止”，点击“仍要打开”。
5. 输入 macOS 登录密码确认。

### 卸载

只想停止使用：退出插件并删除 `GPT Switch.app` 即可。此前保存的自定义模型仍会保留，Codex 重启后依然可见。

要连自定义模型一起移除：先在面板点击“清空并重启”，确认模型选择器中不再有自定义模型，再退出插件并删除 `GPT Switch.app`。如果已经删除了 app，可以手动删除 `~/.codex/model_catalog.json`，并移除 `~/.codex/config.toml` 中的 `model_catalog_json` 配置行（仅当这些是本插件写入的），然后完全退出并重新打开 ChatGPT/Codex；仅刷新页面或只关闭窗口不算完全重启。

## 源码结构

| 文件 | 作用 |
| --- | --- |
| `GPTSwitch` | `.app` 的启动入口，选择 Codex 内置 Node.js |
| `injector.mjs` | 读取模型、启动 Codex、连接本机 CDP 并维护注入状态 |
| `injection.js` | 在模型菜单出现时补充白名单与自定义模型选项 |
| `StatusMenu.swift` | Swift 原生菜单栏与模型配置面板 |
| `model-config.mjs` | 模型校验、配置读写与保存操作 |
| `models.json` | 首次使用的默认模型配置 |
| `Info.plist` | macOS 应用元数据 |
| `AppIcon.png` | 应用图标，取自 ChatGPT 桌面端图标 |
| `MenuBarIcon.png` | 菜单栏图标，ChatGPT 官方模板图（自动适配深浅色） |
| `build.sh` | 生成并临时签名 `.app` |
| `swiftc.sh` | Swift 编译入口，隔离旧工具链的重复模块定义 |
| `test.sh` | 源码和构建产物的静态检查 |
| `.githooks/pre-push` | 推送版本标签时在本地打包并上传安装包 |

## 发布

打标签后推送 `main`，即可在本地打包安装包并上传到对应的 GitHub Release：

```sh
git config core.hooksPath .githooks   # 每个克隆执行一次
git tag -a v0.1.28 -m "Release v0.1.28"
git push origin main
```

`.githooks/pre-push` 在推送 `main` 时，对指向该提交、且尚无 GitHub Release 的版本标签执行本地打包并上传，因此不会再出现只有源码、没有安装包的标签。前置条件：当前分支为 `main`、工作树干净，且 `Info.plist` 版本与标签一致；不满足时会拒绝推送并给出提示。使用 `git push --no-verify` 可跳过该钩子，也可以手动执行 `./local-release.sh prepare <version>` 和 `./local-release.sh publish <version>`。

> 为什么钩子挂在推送 `main` 而不是推送标签：git 在运行 pre-push 之前就已获取远端引用，若在钩子里推送标签会和外层推送竞争同一个引用而失败；本地没有推送完成后的钩子，所以改为在紧跟打标签之后的 `git push origin main` 上触发。

## 兼容性说明

这是针对 Codex 桌面端当前模型菜单结构的运行时适配。桌面端升级后如果改变 Statsig 配置键或 React 菜单结构，可能需要同步更新本项目。

## 免责声明

本项目是非官方的社区工具，与 OpenAI、Codex、ChatGPT 及任何中转服务商不存在隶属、授权或背书关系。项目只调整 Codex 桌面端运行时的前端模型可见性，不会提供或扩大任何账号、API、模型、付费功能或服务权限；模型出现在选择器中不代表对应服务一定可用。

使用第三方中转服务时，请自行评估其安全性、隐私政策和数据处理方式。API 密钥、提示词、文件及模型输出可能会经过该服务商的服务器，本项目无法控制或保证第三方服务的数据安全、稳定性、计费准确性及合规性。

使用者应自行确认其行为符合所在地法律法规，以及 OpenAI、Codex 和所使用服务商的条款。因安装、使用、修改或分发本项目导致的账号限制、数据泄露、费用损失、软件故障或其他直接、间接损失，项目作者及贡献者不承担责任。请在理解源码和风险后自行决定是否使用，并自行备份重要数据。

本项目按“现状”提供，不作任何明示或暗示的担保，包括但不限于适销性、特定用途适用性、兼容性和持续可用性担保。

## 许可证

本项目采用 [MIT License](LICENSE)。允许使用、复制、修改、分发和商用，但必须保留原始版权及许可证声明。软件按“现状”提供，不附带任何担保。

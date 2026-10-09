# GPT Switch

macOS / Windows 桌面工具：在面板里维护多个渠道（渠道地址、渠道 apikey、该渠道的模型列表），启用渠道时把选中的渠道写进 ChatGPT 的配置并重启客户端，同时通过 CDP 把该渠道的模型注入客户端 renderer。

## 它做了什么

- 面板里可以有多个渠道，每个渠道一份「渠道地址 + 渠道 apikey + 模型列表」；每个模型一张卡片，填模型 ID、显示名称、上下文窗口（k，默认 272）和输入类型（文本 / 图片）。
- 点列表里的「启用」时，插件把该渠道写进 ChatGPT 的配置：`~/.codex/config.toml` 里的 `model_provider` 和 `[model_providers.<渠道>]`，以及 `~/.codex/auth.json` 里的 `OPENAI_API_KEY`。
- 渠道列表存在 `~/.gptswitch/channels.json`（Windows 是 `%USERPROFILE%\.gptswitch\channels.json`），和 `~/.codex` 分开；升级插件不会覆盖它。
- 插件启动时不启动或重启 ChatGPT/Codex；点「启用」后，启用一个仅监听 `127.0.0.1` 的随机 Chromium 调试端口并应用配置。
- 通过 CDP 在 renderer 运行时补充 Statsig 白名单和模型列表响应，这部分注入只存在于当前 renderer 会话，重启后失效。
- 启用渠道时会把该渠道的模型合并进模型目录：默认写入 `~/.codex/model_catalog.json`，并在 `~/.codex/config.toml` 中补上 `model_catalog_json` 配置。该目录是磁盘文件，由客户端自己读取，所以插件退出或删除后，已保存的自定义模型仍然保留。
- 点列表页右上角的“还原 ChatGPT 配置并重启”会把插件写过的那部分还原到写入之前的样子（provider 段和 `OPENAI_API_KEY` 都还原），清理插件写入的模型目录和 `model_catalog_json` 配置，然后重启客户端；面板里的渠道列表保留。
- 插件启动后在 macOS 菜单栏显示应用图标，菜单提供“打开面板”和“退出”；打开面板时程序坞和 ⌘Tab 里也会出现 GPT Switch，关掉窗口只是缩回菜单栏，只有菜单里的“退出”会真正结束插件。
- 面板底部显示当前版本并提供“检查更新”：检测到新版本时，可直接打开对应 GitHub Release 下载页。

它不会修改 `ChatGPT.app`、`Codex.app`、`app.asar`、代码签名或历史会话；但会写入 `~/.codex/config.toml`、`~/.codex/auth.json`（渠道密钥）和 `~/.codex/model_catalog.json`。`config.toml` 和 `auth.json` 由 CLI 和桌面端共用，启用渠道会同时影响两边。

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

1. 确认 ChatGPT 桌面端已经安装在 `/Applications/ChatGPT.app`（旧版 `/Applications/Codex.app` 也认）。
2. 双击 `GPT Switch.app`，点击菜单栏图标，选择“打开面板”。
3. 在渠道列表点“添加渠道”，填好 Provider ID、地址、密钥和模型列表，点这一行的「启用」，然后新建任务并打开模型选择器。
4. 需要还原配置时，点列表页右上角的“还原 ChatGPT 配置并重启”，插件会还原 provider 和密钥、清理模型目录并重启客户端。
5. 需要停止插件时，点击 macOS 菜单栏中的插件图标，选择“退出”。

### Windows

Windows 版下载 `GPT-Switch-Setup-<版本>.exe`，安装后从开始菜单打开 `GPT Switch`，会弹出和 macOS 一样的模型配置面板；托盘图标提供“打开面板 / 退出”。

1. 先安装 ChatGPT/Codex 桌面端，商店版和官方独立安装版都可以。
2. 面板里维护渠道（Provider ID / 地址 / 密钥 / 模型），点这一行的「启用」：插件会写 ChatGPT 配置、关掉客户端、带着本机调试端口重新拉起它，再把模型注入进去。
3. 关闭面板窗口只是最小化到任务栏，插件继续在托盘运行；再次点击开始菜单里的 `GPT Switch` 会把面板叫回前台。
4. 要停止插件，右键托盘图标选择“退出”；要移除插件，从开始菜单卸载即可。

Windows 版不额外打包 Node.js：插件优先使用客户端自带的 Node 运行时，找不到时才回退到系统 PATH 里的 node。渠道列表放在 `%USERPROFILE%\.gptswitch`，状态和日志仍在 `%LOCALAPPDATA%\GPTSwitch`。

### 渠道与模型配置

点击菜单栏图标，选择“打开面板”。首页是渠道列表，点「启用」立即写进 ChatGPT 配置并重启；点某一行进入编辑，编辑页右上角是“删除渠道”，列表页右上角是“还原 ChatGPT 配置并重启”。每个渠道填四项：

- Provider ID：写进 `config.toml` 的 `model_providers.<Provider ID>`，只能用字母、数字、`-` 和 `_`。
- 地址：写进 `model_providers.<渠道>.base_url`，例如 `https://choohub.net/api-proxy/v1`。
- 密钥：写进 `~/.codex/auth.json` 的 `OPENAI_API_KEY`。
- 请求头名 / 请求头值：可以留空；填了就写进 `model_providers.<渠道>.http_headers`，用来兼容需要自定义请求头的中转。

下面是这个渠道的模型列表，每个模型一张卡片：模型 ID、显示名称（留空就用模型 ID）、上下文窗口（k）和输入类型。不同渠道的模型列表互相独立，启用渠道时整份列表一起换，卡片右上角的垃圾桶删除该模型。

“模型目录”右边的「获取可用模型」会带着这个渠道的地址、密钥和自定义请求头去问端点的 `GET {地址}/models`，把返回的清单列进「选择要添加的模型」：可以搜索、全选、逐个勾，点「添加所选」才补进当前渠道（已经在目录里的不重复加），点「取消」什么都不动。标准 `data` 数组和部分网关的 `models` 对象都认，显示名取 `name`／`display_name`，窗口取 `context_length`／`context_window` 等字段（token 折成 k）。添加进来的模型只是面板里的编辑内容，点「保存」才落盘。

- “保存”：只把渠道列表写进 `~/.gptswitch/channels.json`，不动 ChatGPT 的配置。
- 「启用」：存盘后把该渠道写进 `~/.codex/config.toml` 和 `auth.json`，更新模型目录，然后重启客户端；`config.toml` 只在启动时读，不重启不生效。
- “还原 ChatGPT 配置并重启”（列表页右上角）：把 ChatGPT 侧还原成插件写入之前的样子，清理模型目录，再重启客户端；面板里的渠道列表保留。若 `model_catalog_json` 在安装插件前就已存在，则保留该配置和文件，只把自定义模型从目录中移除。

首次升级会自动导入现有配置：`~/.codex/config.toml` 里正在使用的 provider、`~/.codex/auth.json` 里的密钥、以及旧版插件保存的模型列表，会合成第一个渠道，不需要重新填一遍。旧的 `~/Library/Application Support/GPTSwitch/models.json`（Windows 是 `%LOCALAPPDATA%\GPTSwitch\models.json`）只作为导入来源，不会被删除。

从 0.1.27 起插件更名为 GPT Switch（原 CodexModelUnlocker）：旧配置目录 `~/Library/Application Support/CodexModelUnlocker/models.json` 也会被一起导入，无需手动迁移。

首次打开如果被 macOS 拦截：

1. 打开“系统设置”。
2. 进入“隐私与安全性”。
3. 往下滚动到“安全性”区域。
4. 找到“GPT Switch.app 已被阻止”，点击“仍要打开”。
5. 输入 macOS 登录密码确认。

### 卸载

只想停止使用：先在面板点“还原 ChatGPT 配置并重启”，把 provider、密钥和模型目录还原，再退出插件并删除 `GPT Switch.app`。

直接退出而不清理的话，客户端会继续指向最后一次启用的渠道，`auth.json` 里也留着那份密钥；想恢复原样再点一次“还原 ChatGPT 配置并重启”即可（面板里的渠道列表会一直保留在 `~/.gptswitch`）。

## 源码结构

| 文件 | 作用 |
| --- | --- |
| `Sources/injector.mjs` | 读取渠道与模型、启动客户端、连接本机 CDP 并维护注入状态（新页面靠浏览器级事件推送发现，事件不可用时每 5 秒兜底轮询） |
| `Sources/injection.js` | 在模型菜单出现时补充白名单与自定义模型选项 |
| `Sources/StatusMenu.swift` | macOS 的 Swift 原生菜单栏与模型配置面板 |
| `Sources/StatusMenu.ps1` | Windows 的桌面面板（PowerShell + WPF），协议与 Swift 面板一致 |
| `Sources/model-config.mjs` | 模型校验、模型目录合并与 `model_catalog_json` 读写 |
| `Sources/channel-config.mjs` | 渠道校验与存储、从现有 `~/.codex` 配置导入、启用/还原 `config.toml` 与 `auth.json`、读取端点公布的模型列表 |
| `Resources/Info.plist` | macOS 应用元数据 |
| `Resources/AppIcon.png` | 应用图标，取自 ChatGPT 桌面端图标 |
| `Resources/MenuBarIcon.png` | 菜单栏图标，ChatGPT 官方模板图（自动适配深浅色） |
| `Scripts/GPTSwitch` | `.app` 的启动入口，选择客户端内置的 Node.js |
| `Scripts/GPTSwitch.ps1` | Windows 启动入口：找 Node、后台起注入器、把已打开的面板叫回前台 |
| `Scripts/build.sh` | 生成并临时签名 `.app` |
| `Scripts/swiftc.sh` | Swift 编译入口，隔离旧工具链的重复模块定义 |
| `Scripts/package-windows.sh` | 用 NSIS 打 Windows 安装包（载荷只有脚本和图标） |
| `Scripts/windows-installer.nsi` | Windows 安装包定义：开始菜单快捷方式、卸载项、卸载前停插件 |
| `Scripts/test.sh` | 源码和构建产物的静态检查 |
| `.github/workflows/release.yml` | 推 `v*` tag 后在 CI 上打包 dmg 与 exe 并发布 Release |

## 兼容性说明

这是针对 ChatGPT 桌面端当前模型菜单结构的运行时适配。桌面端升级后如果改变 Statsig 配置键或 React 菜单结构，可能需要同步更新本项目。

## 免责声明

本项目是非官方的社区工具，与 OpenAI、Codex、ChatGPT 及任何中转服务商不存在隶属、授权或背书关系。项目只调整 ChatGPT 桌面端运行时的前端模型可见性，不会提供或扩大任何账号、API、模型、付费功能或服务权限；模型出现在选择器中不代表对应服务一定可用。

使用者应自行确认其行为符合所在地法律法规，以及 OpenAI、Codex 和所使用服务商的条款。请在理解源码后自行判断风险决定是否使用。

本项目按“现状”提供，不作任何明示或暗示的担保，包括但不限于适销性、特定用途适用性、兼容性和持续可用性担保。

## 许可证

本项目采用 [MIT License](LICENSE)。允许使用、复制、修改、分发和商用，但必须保留原始版权及许可证声明。软件按“现状”提供，不附带任何担保。

# GPT Switch

macOS / Windows 桌面工具：在面板里维护多个渠道（渠道地址、渠道 apikey、该渠道的模型列表），每条渠道可以单独启用/禁用；点「重启」把配置写进 ChatGPT 并重启客户端，同时通过 CDP 把启用渠道的模型注入客户端 renderer。请求走本机 `127.0.0.1` 上的转发服务，按模型 ID 送回对应的渠道。

## 它做了什么

- 面板里可以有多个渠道，每个渠道一份「渠道地址 + 渠道 apikey + 模型列表」；每个模型一张卡片，填模型 ID、显示名称、上下文窗口（k，默认 272）和输入类型（文本 / 图片）。
- 点列表页右上角的「重启」时，插件把配置写进 ChatGPT：`~/.codex/config.toml` 里的 `model_provider` 和 `[model_providers.<渠道>]`（地址指向本机转发服务），以及 `~/.codex/auth.json` 里的 `OPENAI_API_KEY`；如果当前 `model` 不在任何启用渠道的模型列表里，还会把它改成服务渠道的第一个模型。
- 渠道列表存在 `~/.gptswitch/channels.json`（Windows 是 `%USERPROFILE%\.gptswitch\channels.json`），和 `~/.codex` 分开；升级插件不会覆盖它。
- 插件启动时不启动或重启 ChatGPT/Codex；点「重启」后，启用一个仅监听 `127.0.0.1` 的随机 Chromium 调试端口并应用配置。
- 插件启动时还会在本机 `127.0.0.1` 上起一个转发服务：端口优先沿用客户端配置里已经写着的那个（默认 47123，被占用就往后顺延，换端口会记一条日志）：点「重启」时 `base_url` 写的是 `http://127.0.0.1:<端口>/v1`，密钥逐条请求换成渠道自己的。选择器里客户端当前指向的那条渠道保持裸 ID，其它渠道的模型带 `gpts-<渠道 ID>/` 前缀，请求按前缀回到原来那家，所以换渠道不用把客户端指来指去。监听和请求都写死 IPv4 回环地址，不走主机名解析，不受 hosts 文件影响。
- 通过 CDP 在 renderer 运行时补充 Statsig 白名单和模型列表响应，这部分注入只存在于当前 renderer 会话，重启后失效。
- 点「重启」时会把启用渠道的模型合并进模型目录：默认写入 `~/.codex/model_catalog.json`，并在 `~/.codex/config.toml` 中补上 `model_catalog_json` 配置。该目录是磁盘文件，由客户端自己读取，所以插件退出或删除后，已保存的自定义模型仍然保留。
- 点列表页左下角的“初始化配置”会把插件写过的那部分还原到写入之前的样子（provider 段和 `OPENAI_API_KEY` 都还原），清理插件写入的模型目录和 `model_catalog_json` 配置，然后重启客户端；面板里的渠道列表保留。
- 插件启动后在 macOS 菜单栏显示应用图标，菜单提供“打开面板”和“退出”；打开面板时程序坞和 ⌘Tab 里也会出现 GPT Switch（这两处的图标显式设成应用图标，免得系统借启动它的客户端的图标），关掉窗口只是缩回菜单栏，只有菜单里的“退出”会真正结束插件。
- 面板底部显示当前版本，右边是图标形式的“检查更新”：平时是回形箭头，检查中转圈，检测到新版本时换成下载图标（悬停显示当前状态），点一下就打开对应的 GitHub Release 下载页。

它不会修改 `ChatGPT.app`、`Codex.app`、`app.asar`、代码签名或历史会话；但会写入 `~/.codex/config.toml`、`~/.codex/auth.json`（渠道密钥）和 `~/.codex/model_catalog.json`。`config.toml` 和 `auth.json` 由 CLI 和桌面端共用，点「重启」会同时影响两边。

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
3. 在渠道列表点“添加渠道”，填好 Provider ID、地址、密钥和模型列表，点右上角的「重启」，然后新建任务并打开模型选择器。
4. 需要还原配置时，点列表页左下角的“初始化配置”，插件会还原 provider 和密钥、清理模型目录并重启客户端。
5. 需要停止插件时，点击 macOS 菜单栏中的插件图标，选择“退出”。

### Windows

Windows 版下载 `GPT-Switch-Setup-<版本>.exe`，安装后从开始菜单打开 `GPT Switch`，会弹出与 macOS 同源的模型配置面板（界面仍是原来的浅色样式，没有毛玻璃）；托盘图标提供“打开面板 / 退出”。渠道与模型配置两边一致，但底栏提示和跳转还是旧行为：保存后留在编辑页；重启期间按钮文案不变、只是被禁用，进度写在底栏（「正在重启 ChatGPT…」）。

1. 先安装 ChatGPT/Codex 桌面端，商店版和官方独立安装版都可以。
2. 面板里维护渠道（Provider ID / 地址 / 密钥 / 模型），点右上角的「重启」：插件会写 ChatGPT 配置、关掉客户端、带着本机调试端口重新拉起它，再把启用渠道的模型注入进去。
3. 关闭面板窗口只是最小化到任务栏，插件继续在托盘运行；再次点击开始菜单里的 `GPT Switch` 会把面板叫回前台。
4. 要停止插件，右键托盘图标选择“退出”；要移除插件，从开始菜单卸载即可。

Windows 版不额外打包 Node.js：插件优先使用客户端自带的 Node 运行时，找不到时才回退到系统 PATH 里的 node。渠道列表放在 `%USERPROFILE%\.gptswitch`，状态和日志仍在 `%LOCALAPPDATA%\GPTSwitch`。

### 渠道与模型配置

点击菜单栏图标，选择“打开面板”。面板背景是系统毛玻璃材质，跟着系统深浅色走。首页是渠道列表：每条渠道自己一个开关，状态是「已启用」或「已禁用」。点「禁用」只是这一条不能用——它的模型从选择器里消失，请求也会被拒；别的渠道照常，多个渠道可以同时启用，新建的渠道默认启用。点某一行进入编辑，编辑页右上角是“删除渠道”，列表页右上角是「重启」、左下角是“初始化配置”。每个渠道填四项：

- Provider ID：写进 `config.toml` 的 `model_providers.<Provider ID>`，只能用字母、数字、`-` 和 `_`。每个回话会记住自己创建时用的 Provider ID，重开时只按它找表；所以「重启」会把服务渠道同时写进 `config.toml` 里所有用过的 Provider ID（渠道列表 + 插件历史写入记录），旧回话才会跟着一起切。
- 地址：渠道自己那一头。转发服务起着的时候，写进 `model_providers.<渠道>.base_url` 的是本机转发地址 `http://127.0.0.1:<端口>/v1`，渠道地址由转发服务按模型归属去用；转发服务起不来才退回把渠道地址直连写进去（例如 `https://choohub.net/api-proxy/v1`）。
- 密钥：写进 `~/.codex/auth.json` 的 `OPENAI_API_KEY`；面板里默认打码，点右边的眼睛图标可查看。
- 请求头名 / 请求头值：可以留空；填了就写进 `model_providers.<渠道>.http_headers`，用来兼容需要自定义请求头的中转。

下面是这个渠道的模型列表，每个模型一张卡片：模型 ID、显示名称（留空就在保存时按模型 ID 存）、上下文窗口（k）和输入类型。不同渠道的模型列表互相独立，卡片右上角的垃圾桶删除该模型。

模型选择器里只列插件里配置的渠道模型，客户端自带的模型和「默认推荐模型集」不再出现（它们走不到你配置的渠道上）。列表按渠道分组：每个启用的渠道一个可折叠的表头（带条数），点表头折叠或展开这一组，折叠状态只在本次会话里有效；表头名字就是渠道名。只剩一个渠道时照样有表头，显示方式不随渠道数量变。每个渠道的模型在模型目录和输入框上都显示成「模型名（渠道名）」，选择器列表里那一行换成裸模型名（渠道名由表头体现）；客户端当前指向的那条渠道 ID 保持裸名，其它渠道的 ID 带 `gpts-<渠道 ID>/` 前缀。同一个模型 ID 出现在多个渠道时按渠道各算一组，不合并。禁用的渠道不参与分组，它的模型不出现在选择器里。

写进模型目录时，渠道模型一律按「非 Responses Lite」的第三方形状声明：`use_responses_lite = false`、`tool_mode = null`、`shell_type = "shell_command"`、`web_search_tool_type = "text"`、`supports_parallel_tool_calls = true`，并且不带 Fast 这类加速档，取值照 DeepSeek 官方 Codex 接入文档里的 `models.json`。照抄内置模型模板（GPT-5.x 那批是 Lite 形状）会让上游收到它不认识的请求：工具声明被塞进 `input[0].additional_tools`、工具调用改发 `custom_tool_call`、还多一个内部请求头，上游不认时模型只能把工具调用当文本吐出来。

“模型目录”右边的「获取可用模型」会带着这个渠道的地址、密钥和自定义请求头去问端点的 `GET {地址}/models`，把返回的清单列进「选择要添加的模型」：可以搜索、全选、逐个勾，点「添加所选」才补进当前渠道（已经在目录里的不重复加），点「取消」什么都不动。标准 `data` 数组和部分网关的 `models` 对象都认，显示名取 `name`／`display_name`，窗口取 `context_length`／`context_window` 等字段（token 折成 k）。添加进来的模型只是面板里的编辑内容，点「保存」才落盘。

- “保存”：只把渠道列表写进 `~/.gptswitch/channels.json`，不动 ChatGPT 的配置，也不会重启客户端（在编辑页改渠道 ID 也一样）。没有改动时按钮置灰。存盘成功后自动回列表页（重启入口在那儿），底栏提示「配置有更新，点右上角「重启 ChatGPT」生效」；存盘失败则留在编辑页并显示报错，改过的内容不会丢。想把改动送进 ChatGPT，点列表页右上角的「重启」。
- 「启用」/「禁用」：每条渠道自己的开关，点一下只改这一条并落盘，不碰别的渠道、也不重启客户端。只把新的模型列表（插件自己注入的那一份）刷给已经打开的客户端，所以开关立刻生效：禁用的渠道从选择器里消失，选中它的旧会话请求会被转发层拒掉并提示「已经禁用」。删除渠道走同一条路，同样立刻生效、不用重启。新建的渠道默认启用。config.toml 和模型目录是右上角「重启」的事。启用/禁用/删除/重启这些动作不再往底栏写「已禁用渠道…」这类过程提示，底栏留给报错和「配置有更新」的提醒；编辑期的「有未保存的更改」和获取模型的结果照旧显示。
- 「重启」（列表页右上角）：先弹一句「会重启 ChatGPT」，确认后才存盘、把配置写进 `~/.codex/config.toml` 和 `auth.json`、更新模型目录，然后重启客户端；重启期间这个按钮变成「重启中」并置灰，重启完成后恢复；`config.toml` 只在启动时读，不重启不生效。全局 `web_search` 设为 `"live"`，实时抓取最新网页内容；同时把 `show_raw_agent_reasoning` 打开，让第三方模型的裸文本推理在桌面端可见。如果当前 `model` 不在任何启用渠道的模型列表里（例如上一条渠道专属的模型），还会把它改成服务渠道的第一个模型：客户端的选择器只认模型目录里的 id，落不进去就只能显示「自定义」。另外会把 `compact_prompt` 换成「用用户当前使用的语言写压缩摘要、并注明后续继续用该语言」的提示：客户端自带的压缩提示是英文，压缩完接手的那一轮会顺着英文摘要继续用英文推理。这几个键原来是什么值（包括原来没有）都记在还原记录里，「还原」时照原样放回去。
- “初始化配置”（列表页左下角）：把 ChatGPT 侧还原成插件写入之前的样子，清理模型目录，再重启客户端；面板里的渠道列表保留。还原只撤销插件当前还占着的改动：早就不在 `config.toml` 里的 provider 段不会被重新补回来。若 `model_catalog_json` 在安装插件前就已存在，则保留该配置和文件，只把自定义模型从目录中移除。

首次升级会自动导入现有配置：`~/.codex/config.toml` 里正在使用的 provider、`~/.codex/auth.json` 里的密钥、以及旧版插件保存的模型列表，会合成第一个渠道，不需要重新填一遍。旧的 `~/Library/Application Support/GPTSwitch/models.json`（Windows 是 `%LOCALAPPDATA%\GPTSwitch\models.json`）只作为导入来源，不会被删除。

从 0.1.27 起插件更名为 GPT Switch（原 CodexModelUnlocker）：旧配置目录 `~/Library/Application Support/CodexModelUnlocker/models.json` 也会被一起导入，无需手动迁移。

首次打开如果被 macOS 拦截：

1. 打开“系统设置”。
2. 进入“隐私与安全性”。
3. 往下滚动到“安全性”区域。
4. 找到“GPT Switch.app 已被阻止”，点击“仍要打开”。
5. 输入 macOS 登录密码确认。

### 卸载

只想停止使用：先在面板点“初始化配置”，把 provider、密钥和模型目录还原，再退出插件并删除 `GPT Switch.app`。

直接退出而不清理的话，客户端会继续指向本机转发端口 `http://127.0.0.1:<端口>/v1`，插件没在跑时请求就连不上，`auth.json` 里也留着那份密钥；想恢复原样再点一次“初始化配置”即可（面板里的渠道列表会一直保留在 `~/.gptswitch`）。

## 源码结构

| 文件 | 作用 |
| --- | --- |
| `Sources/injector.mjs` | 读取渠道与模型、启动客户端、连接本机 CDP 并维护注入状态（新页面靠浏览器级事件推送发现，事件不可用时每 5 秒兜底轮询） |
| `Sources/injection.js` | 在模型菜单出现时补充白名单与自定义模型选项，并把选择器列表按渠道折叠成组 |
| `Sources/proxy.mjs` | 监听 `127.0.0.1` 的转发服务：按模型 ID 上的 `gpts-<渠道>/` 前缀选渠道，替换密钥与自定义请求头后原样透传（含流式响应） |
| `Sources/StatusMenu.swift` | macOS 的 Swift 原生菜单栏与模型配置面板 |
| `Sources/StatusMenu.ps1` | Windows 的桌面面板（PowerShell + WPF），协议与 Swift 面板一致 |
| `Sources/model-config.mjs` | 模型校验、模型目录合并与 `model_catalog_json` 读写 |
| `Sources/channel-config.mjs` | 渠道校验与存储、从现有 `~/.codex` 配置导入、启用/还原 `config.toml` 与 `auth.json`、读取端点公布的模型列表 |
| `Resources/Info.plist` | macOS 应用元数据 |
| `Resources/AppIcon.png` | 应用图标：结形取自 ChatGPT 桌面端图标，重新配色成青蓝渐变的线稿，和 ChatGPT 官方图标区分开 |
| `Resources/MenuBarIcon.png` | 菜单栏图标：从应用图标里抠出结形、按模板图渲染（自动适配深浅色），和 ChatGPT 官方图标区分开；由 `Resources/AppIcon.png` 生成 |
| `Scripts/GPTSwitch` | `.app` 的启动入口，选择客户端内置的 Node.js |
| `Scripts/GPTSwitch.ps1` | Windows 启动入口：找 Node、后台起注入器、把已打开的面板叫回前台 |
| `Scripts/build.sh` | 生成并临时签名 `.app` |
| `Scripts/swiftc.sh` | Swift 编译入口，隔离旧工具链的重复模块定义 |
| `Scripts/package-windows.sh` | 用 NSIS 打 Windows 安装包（载荷只有脚本和图标） |
| `Scripts/windows-installer.nsi` | Windows 安装包定义：开始菜单快捷方式、卸载项、卸载前停插件 |
| `Scripts/test.sh` | 源码和构建产物的静态检查 |
| `Scripts/local-release.sh` | 本地发布：`prepare` 校验源码并打包 dmg 与 Windows 安装包，`publish` 打 tag 并发布 Release；tag 推送后 CI 也跑同一套，先发布完的一边收工、另一边不重复发布 |
| `.github/workflows/release.yml` | 推 `v*` tag 后在 CI 上打包 dmg 与 exe 并发布 Release |

## 兼容性说明

这是针对 ChatGPT 桌面端当前模型菜单结构的运行时适配。桌面端升级后如果改变 Statsig 配置键或 React 菜单结构，可能需要同步更新本项目。

## 免责声明

本项目是非官方的社区工具，与 OpenAI、Codex、ChatGPT 及任何中转服务商不存在隶属、授权或背书关系。项目只调整 ChatGPT 桌面端运行时的前端模型可见性，不会提供或扩大任何账号、API、模型、付费功能或服务权限；模型出现在选择器中不代表对应服务一定可用。

使用者应自行确认其行为符合所在地法律法规，以及 OpenAI、Codex 和所使用服务商的条款。请在理解源码后自行判断风险决定是否使用。

本项目按“现状”提供，不作任何明示或暗示的担保，包括但不限于适销性、特定用途适用性、兼容性和持续可用性担保。

## 许可证

本项目采用 [MIT License](LICENSE)。允许使用、复制、修改、分发和商用，但必须保留原始版权及许可证声明。软件按“现状”提供，不附带任何担保。

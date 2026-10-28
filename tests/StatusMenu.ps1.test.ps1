$ErrorActionPreference = "Stop"

$sourcePath = Join-Path $PSScriptRoot "..\Sources\StatusMenu.ps1"
$agentStorePath = Join-Path $PSScriptRoot "..\Sources\agents-config.mjs"
if (-not (Select-String -Path $agentStorePath -Pattern 'AGENTS\.md' -Quiet)) {
  throw "公共指令存储路径缺失"
}

# 从源码里取真实函数体来执行，不复制一份实现：副本会和源码漂移，测试就变成假绿。
# 取到的文本必须点源到脚本作用域执行：在函数里 Invoke-Expression 定义的函数，出了那个作用域就没了。
function Get-SourceFunctionText([string]$Name) {
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "解析 $sourcePath 失败：$($errors[0].Message)" }
  $found = $null
  foreach ($node in $ast.FindAll({
    param($astNode) $astNode -is [System.Management.Automation.Language.FunctionDefinitionAst]
  }, $true)) {
    if ($node.Name -eq $Name) { $found = $node; break }
  }
  if ($null -eq $found) { throw "找不到函数：$Name" }
  return $found.Extent.Text
}

# 这是源码片段的行为测试：WPF 面板本身由 Windows probe 的解析步骤覆盖。
. ([scriptblock]::Create((Get-SourceFunctionText "Convert-ResponseChannels")))
. ([scriptblock]::Create((Get-SourceFunctionText "Test-ResponseChannels")))
. ([scriptblock]::Create((Get-SourceFunctionText "Copy-Channels")))
. ([scriptblock]::Create((Get-SourceFunctionText "Compare-Models")))
. ([scriptblock]::Create((Get-SourceFunctionText "Compare-Channels")))
. ([scriptblock]::Create((Get-SourceFunctionText "Test-ProxyDirty")))
. ([scriptblock]::Create((Get-SourceFunctionText "Receive-Response")))
. ([scriptblock]::Create((Get-SourceFunctionText "Get-ChannelIdError")))
. ([scriptblock]::Create((Get-SourceFunctionText "Set-Nav")))
. ([scriptblock]::Create((Get-SourceFunctionText "Show-Models-Page")))
. ([scriptblock]::Create((Get-SourceFunctionText "Show-List-Page")))
. ([scriptblock]::Create((Get-SourceFunctionText "Show-Proxy-Page")))
. ([scriptblock]::Create((Get-SourceFunctionText "Show-Detail-Page")))
. ([scriptblock]::Create((Get-SourceFunctionText "Show-Empty-Page")))
. ([scriptblock]::Create((Get-SourceFunctionText "Apply-Appearance-State")))
. ([scriptblock]::Create((Get-SourceFunctionText "Update-AppearancePreviewAspect")))
. ([scriptblock]::Create((Get-SourceFunctionText "Set-Appearance-Image")))
. ([scriptblock]::Create((Get-SourceFunctionText "New-Appearance-Theme-Card")))
. ([scriptblock]::Create((Get-SourceFunctionText "Update-AgentsControls")))
. ([scriptblock]::Create((Get-SourceFunctionText "Refresh-Agents-View")))
. ([scriptblock]::Create((Get-SourceFunctionText "Show-Agents-Page")))
. ([scriptblock]::Create((Get-SourceFunctionText "Show-Appearance-Page")))
. ([scriptblock]::Create((Get-SourceFunctionText "Show-About-Page")))
. ([scriptblock]::Create((Get-SourceFunctionText "Test-AgentsDirty")))
. ([scriptblock]::Create((Get-SourceFunctionText "Add-SelectedModels")))

if ((Get-ChannelIdError "") -ne "渠道 ID 不能为空") { throw "空渠道 ID 没有提示" }
if ((Get-ChannelIdError "bad id") -ne "渠道 ID 只能用字母、数字、- 和 _") {
  throw "非法渠道 ID 没有提示"
}
$longId = ("a" * 33) -join ""
if ((Get-ChannelIdError $longId) -ne "渠道 ID 不能超过 32 个字符") {
  throw "超长渠道 ID 没有提示"
}
if ($null -ne (Get-ChannelIdError "choohub-gpt")) { throw "合法渠道 ID 被误判" }

$appearancePreviewFrame = [pscustomobject]@{
  ActualWidth = 1120.0
  Height = 210.0
}
Update-AppearancePreviewAspect
if ([Math]::Abs([double]$appearancePreviewFrame.Height - 700.0) -gt 0.01) {
  throw "顶部主题预览没有按 1400×875 的源图比例调整高度"
}
$appearancePreviewFrame.ActualWidth = 560.0
Update-AppearancePreviewAspect
if ([Math]::Abs([double]$appearancePreviewFrame.Height - 350.0) -gt 0.01) {
  throw "窗口宽度变化后顶部主题预览没有保持等比例"
}
$sourceText = Get-Content -LiteralPath $sourcePath -Raw
if ($sourceText -match 'label = "(网页搜索|并行工具)"') {
  throw "模型卡片不应再显示工具能力开关"
}
if ($sourceText -notmatch '\.Text = "输入类型"') {
  throw "模型卡片应只标注输入类型"
}
if ($sourceText -notmatch '\$appearancePreviewFrame\.Add_SizeChanged') {
  throw "顶部主题预览没有监听容器尺寸变化"
}
if ($sourceText -notmatch 'x:Name="AppearancePreviewFrame"[^>]*MaxWidth="560"') {
  throw "顶部主题预览缺少最大宽度限制"
}
if ($sourceText -notmatch 'x:Name="AppearancePreviewFrame"[^>]*HorizontalAlignment="Stretch"') {
  throw "顶部主题预览在首次加载时没有撑满可用宽度"
}
Add-Type -AssemblyName PresentationFramework
$xamlMatch = [regex]::Match($sourceText, '(?s)\[xml\]\$xaml = @"(.*?)"@')
if (-not $xamlMatch.Success) { throw "找不到面板 XAML" }
$xamlReader = New-Object System.Xml.XmlNodeReader ([xml]$xamlMatch.Groups[1].Value)
$xamlPanel = [System.Windows.Markup.XamlReader]::Load($xamlReader)
$activeNav = $xamlPanel.FindName("ModelsTab")
$inactiveNav = $xamlPanel.FindName("ProxyTab")
$activeGlyph = [System.Windows.Shapes.Path]$activeNav.Content.Children[0]
if ($activeGlyph.Width -ne 14 -or $activeGlyph.Height -ne 14 -or
    $activeGlyph.StrokeThickness -ne 1.5) {
  throw "Windows 侧栏图标没有对齐 macOS 的 14px 尺寸和描边"
}
if ($activeNav.Margin.Top -ne 1 -or $activeNav.Margin.Bottom -ne 1 -or
    $inactiveNav.Margin.Top -ne 1 -or $inactiveNav.Margin.Bottom -ne 1) {
  throw "Windows 侧栏按钮没有对齐 macOS 的行间距"
}
if ($activeNav.Background.Color.A -ne 33 -or $activeNav.Background.Color.R -ne 51 -or
    $activeNav.Background.Color.G -ne 107 -or $activeNav.Background.Color.B -ne 64) {
  throw "Windows 侧栏选中态没有对齐 macOS 的 13% accent 底色"
}
$appearanceGlyph = [System.Windows.Shapes.Path]$xamlPanel.FindName("AppearanceTab").Content.Children[0]
$appearanceButtonSource = [regex]::Match(
  $sourceText, '(?s)<Button x:Name="AppearanceTab".*?</Button>').Value
if ($appearanceButtonSource -notmatch '(?s)<Path[^>]*Data="M12,21 A9,9.*?M7\.5,10\.5' -or
    $appearanceGlyph.StrokeThickness -ne 1.5) {
  throw "Windows 外观入口没有使用调色盘图标"
}
if ($xamlPanel.FindName("AppearancePreviewEmptyText").Text -ne "正在读取主题…") {
  throw "外观页加载时没有显示明确的预览状态"
}

$normal = @'
{"channels":[{"id":"ChooHub","name":"ChooHub","models":[]},{"id":"feiyu","name":"feiyu","models":[]}]}
'@ | ConvertFrom-Json
$empty = @'
{"channels":[{"id":""},{"id":""},{"id":""},{"id":""},{"id":""},{"id":""},{"id":""}]}
'@ | ConvertFrom-Json
$detailed = @'
{"channels":[{"id":"relay","name":"Relay","baseUrl":"https://relay.example/v1","apiKey":"sk-relay","headerName":"x-actor","headerValue":"token","enabled":false,"models":[{"id":"m-one","displayName":"M One","context":128,"inputModalities":["text","image"],"supportsSearchTool":true,"supportsParallelToolCalls":false}]}]}
'@ | ConvertFrom-Json

if (-not (Test-ResponseChannels $normal.channels)) { throw "正常渠道回包被拒绝" }
$converted = Convert-ResponseChannels $normal.channels
if ($converted.Count -ne 2 -or $converted[0].id -ne "ChooHub" -or $converted[1].id -ne "feiyu") {
  throw "正常渠道回包被改写"
}
if (Test-ResponseChannels $empty.channels) { throw "空 ID 渠道回包没有被拦住" }
$single = @'
{"channels":[{"id":"relay","name":"Relay","baseUrl":"https://relay.example/v1","models":[]}]}
'@ | ConvertFrom-Json
$singleConverted = Convert-ResponseChannels $single.channels
if ($singleConverted -isnot [array] -or $singleConverted.Count -ne 1 -or
    $singleConverted[0].id -ne "relay") {
  throw "单渠道响应被折叠或转换错误"
}
$singleSnapshot = Copy-Channels $singleConverted
if ($singleSnapshot -isnot [array] -or $singleSnapshot.Count -ne 1 -or
    $singleSnapshot[0].id -ne "relay") {
  throw "单渠道快照被折叠"
}
$draft = Copy-Channels $singleConverted
$draft[0].id = ""
$drawable = @($draft | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.id) })
if ($drawable.Count -ne 0) { throw "空 ID 草稿泄漏到了渠道列表" }
$converted = Convert-ResponseChannels $detailed.channels
if ($converted[0].baseUrl -ne "https://relay.example/v1" -or $converted[0].headerName -ne "x-actor" -or
    $converted[0].enabled -ne $false -or $converted[0].models[0].context -ne 128 -or
    (@($converted[0].models[0].inputModalities) -join ",") -ne "text,image" -or
    $converted[0].models[0].ContainsKey("supportsSearchTool") -or
    $converted[0].models[0].ContainsKey("supportsParallelToolCalls")) {
  throw "渠道回包转换丢了字段"
}
$noEnabled = @'
{"channels":[{"id":"relay","models":[]}]}
'@ | ConvertFrom-Json
if ((Convert-ResponseChannels $noEnabled.channels)[0].enabled -ne $true) {
  throw "渠道没写 enabled 时应当按启用处理"
}
# 快照（Copy-Channels）必须逐字段复制：漏了 enabled 会让「返回」把禁用过的渠道复活，
# 也会让面板一加载就被判成「有未保存的更改」。
$snapshot = Copy-Channels (Convert-ResponseChannels $detailed.channels)
if ($snapshot[0].enabled -ne $false) { throw "复制渠道快照时丢了 enabled" }
if (Compare-Channels (Convert-ResponseChannels $detailed.channels) $snapshot) {
  throw "原样复制的快照被判成了有改动"
}

$script:proxyHost = "127.0.0.1"
$script:proxyPort = "47123"
$script:savedProxyHost = "127.0.0.1"
$script:savedProxyPort = "47123"
if (Test-ProxyDirty) { throw "代理配置原样时被判成有改动" }
$script:proxyPort = "47124"
if (-not (Test-ProxyDirty)) { throw "代理端口改变后没有识别出未保存" }

$script:agentsContent = "原内容"
$script:savedAgentsContent = "原内容"
$script:agentsEnabled = $false
$script:savedAgentsEnabled = $false
if (Test-AgentsDirty) { throw "Agents 原样时被判成有改动" }
$script:agentsContent = "新内容"
if (-not (Test-AgentsDirty)) { throw "Agents 文本改变后没有识别出未保存" }
$script:agentsContent = "原内容"
$script:agentsEnabled = $true
if (-not (Test-AgentsDirty)) { throw "Agents 开关改变后没有识别出未保存" }

# 编辑页保存成功后必须回列表；失败或回包不完整时不能把用户踢出编辑页。
function Get-ActiveChannel {
  if ($script:channelIndex -lt 0 -or $script:channelIndex -ge $script:channels.Count) { return $null }
  return $script:channels[$script:channelIndex]
}
function Update-ChannelFields { }
function Rebuild-Rows { }
function Update-ChannelList { }
function Hide-ModelPicker { }
$script:lastFeedbackText = ""
$script:lastFeedbackError = $false
function Set-Feedback([string]$Text, [bool]$IsError = $false) {
  $script:lastFeedbackText = $Text
  $script:lastFeedbackError = $IsError
}
$script:refreshAppearanceCalls = 0
function Refresh-Appearance-View { $script:refreshAppearanceCalls += 1 }
function Update-Controls { }
$script:showListCalls = 0
function Show-List-Page { $script:showListCalls += 1 }
$appearancePage = [pscustomobject]@{ Visibility = "Visible" }

$script:checkingUpdate = $false
$script:fetchingModels = $false
$script:savingProxy = $false
$script:savingAppearance = $false
$script:cleared = $false
$script:pendingDeleteRestore = $null
$script:pendingDeleteNote = ""
$script:loaded = $true
$script:currentChannelId = "relay"
$script:channelIndex = 0
$script:channels = Convert-ResponseChannels $single.channels
$script:savedChannels = Copy-Channels $script:channels
$script:modelEditorActive = $true

Receive-Response ([pscustomobject]@{
  ok = $true
  saved = $true
  current = "relay"
  channels = $single.channels
})
if ($script:showListCalls -ne 1) { throw "编辑页保存成功后没有返回列表页" }

# 重新导入已有模型保留人工修改的显示名和窗口，忽略端点返回的搜索能力。
$script:channels = Convert-ResponseChannels (@'
{"channels":[{"id":"relay","models":[{"id":"kept","displayName":"手动改的名字","context":64,"inputModalities":["text","image"],"supportsSearchTool":true,"supportsParallelToolCalls":true}]}]}
'@ | ConvertFrom-Json).channels
$script:channelIndex = 0
$script:discoveredModels = @(
  [pscustomobject]@{
    id = "kept"
    supportsSearchTool = $false
    supportsParallelToolCalls = $false
  },
  [pscustomobject]@{
    id = "brand-new"
    displayName = "Brand New"
    supportsParallelToolCalls = $false
  }
)
$script:discoveredSelection = @{ kept = $true; "brand-new" = $true }
Add-SelectedModels
if ($script:channels[0].models.Count -ne 2 -or
    $script:channels[0].models[0].displayName -ne "手动改的名字" -or
    $script:channels[0].models[0].context -ne 64 -or
    $script:channels[0].models[0].ContainsKey("supportsParallelToolCalls") -or
    $script:channels[0].models[1].ContainsKey("supportsParallelToolCalls")) {
  throw "重新导入模型没有按能力刷新，或误改了已有模型设置"
}
if ($script:lastFeedbackText -ne "已添加 1 个模型，点「保存」后生效") {
  throw "重新导入模型后的反馈不准确"
}

$script:showListCalls = 0
$script:modelEditorActive = $true
Receive-Response ([pscustomobject]@{ ok = $false; error = "测试用失败" })
if ($script:showListCalls -ne 0) { throw "编辑页保存失败后不应返回列表页" }

$script:showListCalls = 0
Receive-Response ([pscustomobject]@{ ok = $true; saved = $true; channels = @([pscustomobject]@{ id = "" }) })
if ($script:showListCalls -ne 0) { throw "渠道回包不完整时不应返回列表页" }

# 首次 load 时用户可能已经停在外观页；回包到达后必须立刻把旧加载态换成主题列表。
$script:loaded = $false
$script:busy = $true
$script:channels = @()
$script:savedChannels = @()
$script:channelIndex = -1
$script:currentChannelId = ""
$script:refreshAppearanceCalls = 0
Receive-Response ([pscustomobject]@{
  ok = $true
  current = "relay"
  channels = $single.channels
  appearance = [pscustomobject]@{
    theme = "light"
    followNative = $false
    nativeMode = "light"
    themes = @([pscustomobject]@{
      id = "light"
      name = "浅色"
      previewPath = "light-preview.jpg"
      coverPath = ""
    })
  }
})
if (-not $script:loaded -or $script:appearanceThemes.Count -ne 1 -or
    $script:refreshAppearanceCalls -ne 1) {
  throw "首次完整回包没有把外观页从加载态刷新成主题列表"
}

# 全新安装没有渠道时也不能把已经打开的外观页切回模型列表。
$script:loaded = $false
$script:busy = $true
$script:channels = @()
$script:savedChannels = @()
$script:channelIndex = -1
$script:currentChannelId = ""
$script:refreshAppearanceCalls = 0
$script:showListCalls = 0
Receive-Response ([pscustomobject]@{
  ok = $true
  current = $null
  channels = @()
  appearance = [pscustomobject]@{
    theme = "light"
    followNative = $false
    nativeMode = "light"
    themes = @([pscustomobject]@{
      id = "light"
      name = "浅色"
      previewPath = "light-preview.jpg"
      coverPath = ""
    })
  }
})
if (-not $script:loaded -or $script:appearanceThemes.Count -ne 1 -or
    $script:refreshAppearanceCalls -ne 1 -or $script:showListCalls -ne 0) {
  throw "零渠道首次回包没有保留并刷新外观页"
}

# 首次启动尚未热应用时，主题已经落盘，只提示重启，不能标成保存失败。
$script:appearanceTheme = "dark"
$script:appearanceThemeBeforeSave = "wind"
$script:savingAppearance = $true
$script:busy = $true
Receive-Response ([pscustomobject]@{
  ok = $true
  restartRequired = $true
  appearance = [pscustomobject]@{ theme = "dark"; themes = @() }
})
if ($script:lastFeedbackText -ne "主题已保存，重启 ChatGPT 后生效" -or
    $script:lastFeedbackError -ne $false -or $script:savingAppearance -or $script:busy) {
  throw "重启提示的状态、颜色或忙碌标记不正确"
}

# 真正写盘失败才是红色错误，并把面板恢复到保存前的主题。
$script:appearanceTheme = "dark"
$script:appearanceThemeBeforeSave = "wind"
$script:savingAppearance = $true
$script:busy = $true
Receive-Response ([pscustomobject]@{ ok = $false; error = "主题写入失败" })
if ($script:appearanceTheme -ne "wind" -or
    $script:lastFeedbackText -ne "主题写入失败" -or
    $script:lastFeedbackError -ne $true -or $script:savingAppearance -or $script:busy) {
  throw "主题写入失败没有恢复旧主题或没有显示红色错误"
}

# Codex 原生模式广播到达后，GPT Switch 覆盖暂停并同步选中对应原生主题。
$script:appearanceTheme = "wind"
$script:appearanceFollowNative = $false
$script:savingAppearance = $false
$script:busy = $false
Receive-Response ([pscustomobject]@{
  event = "appearance-updated"
  appearance = [pscustomobject]@{
    theme = "dark"; followNative = $true; nativeMode = "dark"; themes = @()
  }
})
if (-not $script:appearanceFollowNative -or
    $script:appearanceNativeMode -ne "dark" -or
    $script:appearanceTheme -ne "dark" -or
    $script:lastFeedbackText -ne "") {
  throw "原生模式广播没有暂停覆盖、同步选中主题或清空提示"
}

# 从“跟随原生”重新启用主题失败时，完整恢复主题、跟随标记和原生模式。
$script:appearanceTheme = "wind"
$script:appearanceThemeBeforeSave = "wind"
$script:appearanceFollowNativeBeforeSave = $true
$script:appearanceNativeModeBeforeSave = "dark"
$script:appearanceFollowNative = $false
$script:savingAppearance = $true
$script:busy = $true
Receive-Response ([pscustomobject]@{ ok = $false; error = "重新启用主题失败" })
if (-not $script:appearanceFollowNative -or
    $script:appearanceNativeMode -ne "dark" -or
    $script:lastFeedbackText -ne "重新启用主题失败") {
  throw "重新启用主题失败后没有恢复完整外观状态"
}

$script:savingProxy = $true
$script:busy = $true
Receive-Response ([pscustomobject]@{
  event = "appearance-updated"
  appearance = [pscustomobject]@{
    theme = "light"; followNative = $true; nativeMode = "light"; themes = @()
  }
})
if (-not $script:savingProxy -or -not $script:busy) {
  throw "主动外观事件抢走了正在等待的代理保存响应"
}
if ($script:appearanceTheme -ne "light") {
  throw "主动外观事件没有同步选中原生浅色主题"
}
$script:savingProxy = $false
$script:busy = $false

# 侧栏导航使用共享的假控件记录可见性和导航样式，实际执行源码中的页面切换函数。
function New-TestControl {
  $control = [pscustomobject]@{
    Text = ""
    IsChecked = $false
    IsEnabled = $true
    Visibility = "Collapsed"
    testStyle = $null
  }
  $control | Add-Member -MemberType ScriptProperty -Name Style -Value {
    $this.testStyle
  } -SecondValue {
    param($value)
    $this.testStyle = $value
  }
  return $control
}

$listPage = New-TestControl
$detailPage = New-TestControl
$simplePage = New-TestControl
$aboutPage = New-TestControl
$agentsPage = New-TestControl
$appearancePage = New-TestControl
$modelsPage = New-TestControl
$modelsCard = New-TestControl
$proxyPage = New-TestControl
$simplePageTitle = New-TestControl
$agentsContentField = New-TestControl
$agentsEnabledToggle = New-TestControl
$saveAgentsButton = New-TestControl
$agentsBackupLabel = New-TestControl
$agentsErrorLabel = New-TestControl
$proxyHostField = New-TestControl
$proxyPortField = New-TestControl
$modelsTab = New-TestControl
$proxyTab = New-TestControl
$generalTab = New-TestControl
$appearanceTab = New-TestControl
$agentsTab = New-TestControl
$aboutTab = New-TestControl
$helpTab = New-TestControl

# 页面函数只读取资源名来切换导航样式，测试桩返回同一名称即可。
$window = [pscustomobject]@{}
$window | Add-Member -MemberType ScriptMethod -Name FindResource -Value {
  param([string]$Name)
  return $Name
}

# 源码函数通过 Windows PowerShell 的全局变量解析控件；测试桩也必须放在同一作用域。
foreach ($name in @(
  "listPage", "detailPage", "simplePage", "aboutPage", "agentsPage", "appearancePage",
  "modelsPage", "modelsCard", "proxyPage", "simplePageTitle",
  "agentsContentField", "agentsEnabledToggle", "saveAgentsButton", "agentsBackupLabel", "agentsErrorLabel",
  "proxyHostField", "proxyPortField", "modelsTab", "proxyTab", "generalTab",
  "appearanceTab", "agentsTab", "aboutTab", "helpTab", "window"
)) {
  $value = Get-Variable -Name $name -ValueOnly
  Set-Variable -Name $name -Value $value -Scope Global
}

# 前一段回包测试临时替换了 Show-List-Page；导航测试必须恢复源码函数，不能拿测试桩冒充页面切换。
. ([scriptblock]::Create((Get-SourceFunctionText "Show-List-Page")))

function Assert-Navigation([string]$Active, [string]$VisiblePage) {
  $tabNames = @{
    models = $modelsTab
    proxy = $proxyTab
    general = $generalTab
    appearance = $appearanceTab
    agents = $agentsTab
    about = $aboutTab
    help = $helpTab
  }
  foreach ($key in $tabNames.Keys) {
    $expected = if ($key -eq $Active) { "NavActive" } else { "Nav" }
    if ($tabNames[$key].Style -ne $expected) {
      throw "导航 $Active 时 $key 的高亮状态错误：实际=$($tabNames[$key].Style)，期望=$expected"
    }
  }
  foreach ($pageName in @("listPage", "detailPage", "simplePage", "aboutPage", "agentsPage", "appearancePage")) {
    $actual = (Get-Variable -Name $pageName -ValueOnly).Visibility
    $expected = if ($pageName -eq $VisiblePage) { "Visible" } else { "Collapsed" }
    if ($actual -ne $expected) {
      throw "导航 $Active 时 $pageName 的可见性错误：$actual"
    }
  }
}

$script:modelEditorActive = $false
Show-Models-Page
Assert-Navigation "models" "listPage"

$script:modelEditorActive = $true
Show-Models-Page
Assert-Navigation "models" "detailPage"

Show-Proxy-Page
Assert-Navigation "proxy" "listPage"
if ($proxyPage.Visibility -ne "Visible" -or $modelsPage.Visibility -ne "Collapsed" -or
    $modelsCard.Visibility -ne "Collapsed") {
  throw "代理页没有切换到正确的子页面"
}

Show-Empty-Page "通用" "general"
Assert-Navigation "general" "simplePage"
Show-Appearance-Page
Assert-Navigation "appearance" "appearancePage"

Show-Agents-Page
Assert-Navigation "agents" "agentsPage"

Show-About-Page
Assert-Navigation "about" "aboutPage"
Show-Empty-Page "获取帮助" "help"
Assert-Navigation "help" "simplePage"

# 动态创建的 WPF 按钮必须显式接收 sender；PowerShell 不会自动提供这个变量。
Add-Type -AssemblyName PresentationFramework
$window = [pscustomobject]@{}
$window | Add-Member -MemberType ScriptMethod -Name FindResource -Value {
  param([string]$Name)
  return $xamlPanel.FindResource($Name)
}
$script:appearanceTheme = "dark"
$script:loaded = $true
$script:busy = $false
$script:selectedAppearanceTheme = ""
function Select-Appearance-Theme([string]$ThemeId) {
  $script:selectedAppearanceTheme = $ThemeId
}
$themeCard = New-Appearance-Theme-Card ([pscustomobject]@{
  id = "dark"
  name = "深色"
  coverPath = ""
})
$themeButton = [System.Windows.Controls.Button]$themeCard.Children[0]
$themeButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
if ($script:selectedAppearanceTheme -ne "dark") {
  throw "Windows 主题卡片点击没有把主题 ID 传给选择函数"
}
$themeFrame = [System.Windows.Controls.Border]$themeButton.Content
$themeOverlay = [System.Windows.Controls.Grid]$themeFrame.Child
$selectedBadge = [System.Windows.Controls.Border]$themeOverlay.Children[1]
if ($selectedBadge.Width -ne 18 -or $selectedBadge.Height -ne 18 -or
    $selectedBadge.CornerRadius.TopLeft -ne 9) {
  throw "Windows 主题选中标记没有使用 macOS 风格的圆形徽标"
}

# Windows 的确认框类型只能在 Windows PowerShell 中实例化；这里检查六个离开入口都没有绕过确认函数。
foreach ($name in @("ModelsTab", "ProxyTab", "GeneralTab", "AppearanceTab", "AboutTab", "HelpTab")) {
  $pattern = "\`$$($name[0].ToString().ToLower())$($name.Substring(1)).Add_Click\(\{ if \(Confirm-AgentsLeave\)"
  if (-not (Select-String -Path $sourcePath -Pattern $pattern -Quiet)) {
    throw "侧栏入口 $name 缺少 Agents 未保存确认"
  }
}
if ($sourceText -notmatch '(?s)\$quitItem\.Add_Click\(\{\s*if \(-not \(Confirm-AgentsDiscard') {
  throw "托盘退出没有确认并清理未保存的 Agents 草稿"
}
$discardFunction = Get-SourceFunctionText "Confirm-AgentsDiscard"
if ($discardFunction -notmatch 'Refresh-Agents-View') {
  throw "确认放弃 Agents 草稿后没有刷新可见编辑框"
}

Write-Output "Windows 面板渠道响应和侧栏导航检查通过"

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
. ([scriptblock]::Create((Get-SourceFunctionText "Update-AgentsControls")))
. ([scriptblock]::Create((Get-SourceFunctionText "Refresh-Agents-View")))
. ([scriptblock]::Create((Get-SourceFunctionText "Show-Agents-Page")))
. ([scriptblock]::Create((Get-SourceFunctionText "Show-About-Page")))

if ((Get-ChannelIdError "") -ne "渠道 ID 不能为空") { throw "空渠道 ID 没有提示" }
if ((Get-ChannelIdError "bad id") -ne "渠道 ID 只能用字母、数字、- 和 _") {
  throw "非法渠道 ID 没有提示"
}
$longId = ("a" * 33) -join ""
if ((Get-ChannelIdError $longId) -ne "渠道 ID 不能超过 32 个字符") {
  throw "超长渠道 ID 没有提示"
}
if ($null -ne (Get-ChannelIdError "choohub-gpt")) { throw "合法渠道 ID 被误判" }

$normal = @'
{"channels":[{"id":"ChooHub","name":"ChooHub","models":[]},{"id":"feiyu","name":"feiyu","models":[]}]}
'@ | ConvertFrom-Json
$empty = @'
{"channels":[{"id":""},{"id":""},{"id":""},{"id":""},{"id":""},{"id":""},{"id":""}]}
'@ | ConvertFrom-Json
$detailed = @'
{"channels":[{"id":"relay","name":"Relay","baseUrl":"https://relay.example/v1","apiKey":"sk-relay","headerName":"x-actor","headerValue":"token","enabled":false,"models":[{"id":"m-one","displayName":"M One","context":128,"inputModalities":["text","image"]}]}]}
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
    (@($converted[0].models[0].inputModalities) -join ",") -ne "text,image") {
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

# 编辑页保存成功后必须回列表；失败或回包不完整时不能把用户踢出编辑页。
function Get-ActiveChannel {
  if ($script:channelIndex -lt 0 -or $script:channelIndex -ge $script:channels.Count) { return $null }
  return $script:channels[$script:channelIndex]
}
function Update-ChannelFields { }
function Rebuild-Rows { }
function Update-ChannelList { }
function Set-Feedback([string]$Text, [bool]$IsError = $false) { }
function Update-Controls { }
$script:showListCalls = 0
function Show-List-Page { $script:showListCalls += 1 }

$script:checkingUpdate = $false
$script:fetchingModels = $false
$script:savingProxy = $false
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

$script:showListCalls = 0
$script:modelEditorActive = $true
Receive-Response ([pscustomobject]@{ ok = $false; error = "测试用失败" })
if ($script:showListCalls -ne 0) { throw "编辑页保存失败后不应返回列表页" }

$script:showListCalls = 0
Receive-Response ([pscustomobject]@{ ok = $true; saved = $true; channels = @([pscustomobject]@{ id = "" }) })
if ($script:showListCalls -ne 0) { throw "渠道回包不完整时不应返回列表页" }

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
  "listPage", "detailPage", "simplePage", "aboutPage", "agentsPage",
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
  foreach ($pageName in @("listPage", "detailPage", "simplePage", "aboutPage", "agentsPage")) {
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
Show-Empty-Page "外观" "appearance"
Assert-Navigation "appearance" "simplePage"

Show-Agents-Page
Assert-Navigation "agents" "agentsPage"

Show-About-Page
Assert-Navigation "about" "aboutPage"
Show-Empty-Page "获取帮助" "help"
Assert-Navigation "help" "simplePage"

# Windows 的确认框类型只能在 Windows PowerShell 中实例化；这里检查六个离开入口都没有绕过确认函数。
foreach ($name in @("ModelsTab", "ProxyTab", "GeneralTab", "AppearanceTab", "AboutTab", "HelpTab")) {
  $pattern = "\`$$($name[0].ToString().ToLower())$($name.Substring(1)).Add_Click\(\{ if \(Confirm-AgentsLeave\)"
  if (-not (Select-String -Path $sourcePath -Pattern $pattern -Quiet)) {
    throw "侧栏入口 $name 缺少 Agents 未保存确认"
  }
}

Write-Output "Windows 面板渠道响应和侧栏导航检查通过"

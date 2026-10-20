$ErrorActionPreference = "Stop"

$sourcePath = Join-Path $PSScriptRoot "..\Sources\StatusMenu.ps1"

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

Write-Output "Windows 面板渠道响应检查通过"

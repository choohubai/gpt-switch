$ErrorActionPreference = "Stop"

$sourcePath = Join-Path $PSScriptRoot "..\Sources\StatusMenu.ps1"
$source = [string](Get-Content -LiteralPath $sourcePath -Raw)

function Get-FunctionBlock([string]$Name) {
  $pattern = '(?ms)^function\s+' + [regex]::Escape($Name) + '\s*\{.*?^\}'
  $match = [regex]::Match($source, $pattern)
  if (-not $match.Success) { throw "找不到函数：$Name" }
  return $match.Value
}

# 只执行响应回填这一段，不加载 WPF。
Invoke-Expression (Get-FunctionBlock "Convert-ResponseChannels")
Invoke-Expression (Get-FunctionBlock "Test-ResponseChannels")

$normal = @'
{"channels":[{"id":"ChooHub","name":"ChooHub","models":[]},{"id":"feiyu","name":"feiyu","models":[]}]}
'@ | ConvertFrom-Json
$empty = @'
{"channels":[{"id":""},{"id":""},{"id":""},{"id":""},{"id":""},{"id":""},{"id":""}]}
'@ | ConvertFrom-Json
$models = @'
{"channels":[{"id":"ChooHub","models":[{"id":"deepseek-v4-pro","webSearch":true},{"id":"glm-5.3","webSearch":false},{"id":"gpt-6-astra"}]}]}
'@ | ConvertFrom-Json

if (-not (Test-ResponseChannels $normal.channels)) { throw "正常渠道回包被拒绝" }
$converted = Convert-ResponseChannels $normal.channels
if ($converted.Count -ne 2 -or $converted[0].id -ne "ChooHub" -or $converted[1].id -ne "feiyu") {
  throw "正常渠道回包被改写"
}
if (Test-ResponseChannels $empty.channels) { throw "空 ID 渠道回包没有被拦住" }
$converted = Convert-ResponseChannels $models.channels
if ($converted[0].models[0].webSearch -ne $true -or
    $converted[0].models[1].webSearch -ne $false -or
    $null -ne $converted[0].models[2].webSearch) {
  throw "模型网页搜索状态在 Windows 回包转换中丢失"
}

Write-Output "Windows 面板渠道响应检查通过"

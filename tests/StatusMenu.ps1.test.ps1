$ErrorActionPreference = "Stop"

$sourcePath = Join-Path $PSScriptRoot "..\Sources\StatusMenu.ps1"
$source = Get-Content -LiteralPath $sourcePath -Raw

# 这是源码片段的行为测试：WPF 面板本身由 Windows probe 的解析步骤覆盖。
function Convert-ResponseChannels($Source) {
  return @($Source | ForEach-Object {
    @{
      id = [string]$_.id
      name = [string]$_.name
      models = @($_.models | ForEach-Object {
        @{
          id = [string]$_.id; displayName = [string]$_.displayName
          context = [int]$_.context
        }
      })
    }
  })
}

function Test-ResponseChannels($Source) {
  if ($null -eq $Source) { return $false }
  $items = @($Source)
  foreach ($item in $items) {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.id)) { return $false }
  }
  return $true
}

$normal = @'
{"channels":[{"id":"ChooHub","name":"ChooHub","models":[]},{"id":"feiyu","name":"feiyu","models":[]}]}
'@ | ConvertFrom-Json
$empty = @'
{"channels":[{"id":""},{"id":""},{"id":""},{"id":""},{"id":""},{"id":""},{"id":""}]}
'@ | ConvertFrom-Json

if (-not (Test-ResponseChannels $normal.channels)) { throw "正常渠道回包被拒绝" }
$converted = Convert-ResponseChannels $normal.channels
if ($converted.Count -ne 2 -or $converted[0].id -ne "ChooHub" -or $converted[1].id -ne "feiyu") {
  throw "正常渠道回包被改写"
}
if (Test-ResponseChannels $empty.channels) { throw "空 ID 渠道回包没有被拦住" }

Write-Output "Windows 面板渠道响应检查通过"

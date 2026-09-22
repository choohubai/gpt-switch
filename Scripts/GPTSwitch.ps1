# GPT Switch 启动器：对应 macOS 的 Scripts/GPTSwitch。
# 由快捷方式用隐藏窗口的 powershell 拉起，所以这里不出现控制台窗口。
# -Stop 供卸载程序调用：结束本安装目录下的注入器和面板。
param([switch]$Stop)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$InformationPreference = "SilentlyContinue"
$WarningPreference = "SilentlyContinue"

$installDir = $PSScriptRoot
$injector = Join-Path $installDir "injector.mjs"

Add-Type -Namespace GPTSwitch -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string className, string windowName);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr handle, int command);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr handle, out uint processId);
'@

function Show-Message([string]$Message) {
  Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
  try {
    [System.Windows.MessageBox]::Show($Message, "GPT Switch", "OK", "Warning") | Out-Null
  } catch {
    Write-Host $Message
  }
}

# 卸载前清理：停掉本安装目录下的注入器和面板（不含当前进程）。
if ($Stop) {
  Get-CimInstance Win32_Process -Filter "Name='node.exe' or Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($installDir) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  exit 0
}

# 插件已经在跑：把面板窗口提到前台，不再启动第二个实例。
# 类名必须用 [NullString]::Value：PowerShell 的 $null 会marshal成空串，FindWindow 就找不到窗口。
$handle = [GPTSwitch.Native]::FindWindowW([NullString]::Value, "GPT Switch")
if ($handle -and $handle -ne [IntPtr]::Zero) {
  $owner = 0
  [void][GPTSwitch.Native]::GetWindowThreadProcessId($handle, [ref]$owner)
  $process = Get-Process -Id $owner -ErrorAction SilentlyContinue
  if ($process -and $process.ProcessName -eq "powershell") {
    [void][GPTSwitch.Native]::ShowWindow($handle, 9)
    [void][GPTSwitch.Native]::SetForegroundWindow($handle)
    exit 0
  }
}

function Find-NodeRuntime {
  # 1) 客户端按用户安装的运行时（版本跟客户端一致）
  $runtimeRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\runtimes\cua_node"
  $candidates = @()
  if (Test-Path -LiteralPath $runtimeRoot) {
    $candidates += Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      ForEach-Object { Join-Path $_.FullName "bin\node.exe" }
  }
  # 2) 独立安装版客户端自带的 node
  $programs = Join-Path $env:LOCALAPPDATA "Programs"
  if (Test-Path -LiteralPath $programs) {
    $candidates += Get-ChildItem -LiteralPath $programs -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match "^(Codex|ChatGPT)" } |
      Sort-Object LastWriteTime -Descending |
      ForEach-Object { Join-Path $_.FullName "resources\cua_node\bin\node.exe" }
  }
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  # 3) 系统 PATH 里的 node
  $system = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($system) { return $system.Source }
  return $null
}

if (-not (Test-Path -LiteralPath $injector)) {
  Show-Message "安装目录不完整，找不到 injector.mjs：`n$injector`n`n请重新安装 GPT Switch。"
  exit 1
}

$node = Find-NodeRuntime
if (-not $node) {
  Show-Message "未找到 Node.js 运行时。`n`n请安装 ChatGPT/Codex 桌面端，或自行安装 Node.js 22 以上版本后重试。"
  exit 1
}

# 注入器常驻后台：隐藏窗口启动，不等它结束。
Start-Process -FilePath $node -ArgumentList @("`"$injector`"") -WindowStyle Hidden -WorkingDirectory $installDir | Out-Null
exit 0
$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent $PSScriptRoot
$testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gpt-switch-host-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testDir | Out-Null
$hostPath = Join-Path $testDir "GPT Switch.exe"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw $Message
  }
}

function Invoke-HostCapture([string[]]$HostArguments) {
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $hostPath
  $info.Arguments = ($HostArguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join " "
  $info.WorkingDirectory = $testDir
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $info.RedirectStandardError = $true
  $info.RedirectStandardOutput = $true
  $process = [System.Diagnostics.Process]::Start($info)
  try {
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Stdout = $stdout
      Stderr = $stderr
    }
  } finally {
    $process.Dispose()
  }
}

try {
  & (Join-Path $rootDir "Scripts\build-windows-host.ps1") -OutputPath $hostPath | Out-Null
  $missingPanel = Invoke-HostCapture @("--panel")
  Assert-True ($missingPanel.ExitCode -eq 1) "Missing panel should fail."
  $missingPanelPrefix = -join ([char[]](0x627E, 0x4E0D, 0x5230))
  Assert-True ($missingPanel.Stderr.Contains($missingPanelPrefix)) `
    "Native panel errors are not UTF-8: $($missingPanel.Stderr)"
  Copy-Item -LiteralPath (Join-Path $rootDir "Sources\StatusMenu.ps1") -Destination $testDir

  $stream = [System.IO.File]::OpenRead($hostPath)
  $reader = New-Object System.IO.BinaryReader($stream)
  try {
    $stream.Position = 0x3c
    $peOffset = $reader.ReadInt32()
    $stream.Position = $peOffset + 24 + 68
    $subsystem = $reader.ReadUInt16()
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
  Assert-True ($subsystem -eq 2) "Native launcher must use the Windows GUI subsystem."
  $runningPaths = Invoke-HostCapture @("--running-client-paths")
  Assert-True ($runningPaths.ExitCode -eq 0) "Native client path probe failed: $($runningPaths.Stderr)"
  $packagedApp = Invoke-HostCapture @("--packaged-app")
  Assert-True ($packagedApp.ExitCode -eq 0) "Native packaged app probe failed: $($packagedApp.Stderr)"
  if (-not [string]::IsNullOrWhiteSpace($packagedApp.Stdout)) {
    $packagedFields = ($packagedApp.Stdout.Trim() -split "\|")
    Assert-True ($packagedFields.Count -eq 4) `
      "Packaged app probe must return install location, activation ID, executable and execution alias."
    Assert-True ($packagedFields[3].EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) `
      "Packaged app probe returned an invalid execution alias: $($packagedFields[3])"
  }
  $activationFailure = Invoke-HostCapture @("--activate-app", "invalid-package", "")
  Assert-True ($activationFailure.ExitCode -ne 0) "Invalid package activation unexpectedly succeeded."
  Assert-True (-not [string]::IsNullOrWhiteSpace($activationFailure.Stderr)) `
    "Invalid package activation did not report an error."

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $hostPath
  $startInfo.Arguments = "--panel --parent-pid $PID"
  $startInfo.WorkingDirectory = $testDir
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true

  $panel = [System.Diagnostics.Process]::Start($startInfo)
  try {
    $lineTask = $panel.StandardOutput.ReadLineAsync()
    Assert-True ($lineTask.Wait(15000)) "Native panel did not send its initial load request."
    $line = $lineTask.Result
    Assert-True ($null -ne $line -and $line.Contains('"action":"load"')) "Unexpected panel output: $line"
    Assert-True ($panel.ProcessName -eq "GPT Switch") "Panel process is not GPT Switch.exe: $($panel.ProcessName)"

    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($panel.Id)")
    $powerShellChildren = @($children | Where-Object { $_.Name -ieq "powershell.exe" })
    Assert-True ($powerShellChildren.Count -eq 0) "Native panel spawned powershell.exe."

    $panel.StandardInput.Close()
    Assert-True ($panel.WaitForExit(15000)) "Native panel did not close after stdin closed."
    Assert-True ($panel.ExitCode -eq 0) "Native panel exited with code $($panel.ExitCode)."
  } finally {
    if (-not $panel.HasExited) {
      $panel.Kill()
      [void]$panel.WaitForExit(5000)
    }
    $panel.Dispose()
  }

  $runningScript = Join-Path $testDir "running.mjs"
  @'
setInterval(() => {}, 1000);
'@ | Set-Content -LiteralPath $runningScript -Encoding ASCII
  $node = (Get-Command node.exe -ErrorAction Stop).Source
  $running = Start-Process -FilePath $node -ArgumentList "`"$runningScript`"" `
    -WorkingDirectory $testDir -WindowStyle Hidden -PassThru
  try {
    Start-Sleep -Milliseconds 500
    $stopper = Start-Process -FilePath $hostPath -ArgumentList "--stop" -Wait -PassThru
    try {
      Assert-True ($stopper.ExitCode -eq 0) "Native launcher --stop failed."
    } finally {
      $stopper.Dispose()
    }
    Assert-True ($running.WaitForExit(10000)) "Native launcher --stop left the injector running."
  } finally {
    if (-not $running.HasExited) {
      $running.Kill()
      [void]$running.WaitForExit(5000)
    }
    $running.Dispose()
  }

  $injectorPath = Join-Path $testDir "injector.mjs"
  @'
import fs from "node:fs";
fs.writeFileSync("launcher-ran.txt", process.argv[1]);
'@ | Set-Content -LiteralPath $injectorPath -Encoding ASCII
  $launcherInfo = New-Object System.Diagnostics.ProcessStartInfo
  $launcherInfo.FileName = $hostPath
  $launcherInfo.WorkingDirectory = $testDir
  $launcherInfo.UseShellExecute = $false
  $launcherInfo.CreateNoWindow = $true
  $launcherInfo.RedirectStandardError = $true
  $launcherInfo.RedirectStandardOutput = $true
  $launcher = [System.Diagnostics.Process]::Start($launcherInfo)
  Assert-True ($launcher.WaitForExit(10000)) "Default launcher did not exit after starting the injector."
  Assert-True ($launcher.ExitCode -eq 0) "Default launcher exited with code $($launcher.ExitCode)."
  $launcher.Dispose()

  $marker = Join-Path $testDir "launcher-ran.txt"
  for ($attempt = 0; $attempt -lt 50 -and -not (Test-Path -LiteralPath $marker); $attempt++) {
    Start-Sleep -Milliseconds 100
  }
  Assert-True (Test-Path -LiteralPath $marker) "Default launcher did not start injector.mjs."
  Assert-True ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $injectorPath) "Injector path was not passed to Node."

  Write-Host "Windows native launcher test passed."
} finally {
  Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
}

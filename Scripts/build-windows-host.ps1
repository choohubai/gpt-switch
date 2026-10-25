param(
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $rootDir "Sources\WindowsLauncher.cs"
$iconSource = Join-Path $rootDir "Resources\AppIcon.png"
if (-not $OutputPath) {
  $OutputPath = Join-Path $rootDir "dist\windows-host\GPT Switch.exe"
}
$outputDir = Split-Path -Parent $OutputPath

$frameworkCandidates = @(
  (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
  (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$csc = $frameworkCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
  throw "Windows .NET Framework C# compiler was not found."
}

$automation = Get-ChildItem `
  -LiteralPath (Join-Path $env:WINDIR "Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation") `
  -Recurse -Filter "System.Management.Automation.dll" |
  Where-Object { $_.FullName -match "v4\.0_3\.0\.0\.0" } |
  Select-Object -First 1
if (-not $automation) {
  throw "Windows PowerShell 5.1 automation assembly was not found."
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$iconPath = Join-Path ([System.IO.Path]::GetTempPath()) ("gpt-switch-icon-" + [guid]::NewGuid().ToString("N") + ".ico")

Add-Type -AssemblyName System.Drawing
$sourceImage = [System.Drawing.Image]::FromFile($iconSource)
$bitmap = New-Object System.Drawing.Bitmap 256, 256
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$png = New-Object System.IO.MemoryStream
try {
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.DrawImage($sourceImage, 0, 0, 256, 256)
  $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  $pngBytes = $png.ToArray()
  $writer = New-Object System.IO.BinaryWriter([System.IO.File]::Create($iconPath))
  try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]1)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$pngBytes.Length)
    $writer.Write([uint32]22)
    $writer.Write($pngBytes)
  } finally {
    $writer.Dispose()
  }
} finally {
  $png.Dispose()
  $graphics.Dispose()
  $bitmap.Dispose()
  $sourceImage.Dispose()
}

try {
  & $csc `
    /nologo `
    /target:winexe `
    /platform:anycpu `
    /optimize+ `
    /codepage:65001 `
    "/out:$OutputPath" `
    "/win32icon:$iconPath" `
    "/reference:$($automation.FullName)" `
    $sourcePath
  if ($LASTEXITCODE -ne 0) {
    throw "C# compiler exited with code $LASTEXITCODE."
  }
} finally {
  Remove-Item -LiteralPath $iconPath -Force -ErrorAction SilentlyContinue
}

$output = Get-Item -LiteralPath $OutputPath
if ($output.Length -le 0) {
  throw "Native launcher was not created: $OutputPath"
}
$output.FullName

param(
  [int]$ParentPid = 0,
  [string]$IconPath = ""
)

# Windows 面板：StatusMenu.swift 的对应实现。
# 与注入器之间用和 macOS 相同的协议通信：stdout 发请求，stdin 收响应。
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$InformationPreference = "SilentlyContinue"
$WarningPreference = "SilentlyContinue"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing

Add-Type -Namespace GPTSwitch -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string className, string windowName);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr handle, int command);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
[DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr handle);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
'@

try { [void][GPTSwitch.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) }
catch { try { [void][GPTSwitch.Native]::SetProcessDPIAware() } catch { } }

# 让任务栏把面板当成独立应用，而不是 PowerShell 的一个窗口。
try { [void][GPTSwitch.Native]::SetCurrentProcessExplicitAppUserModelID("choohubai.GPTSwitch") } catch { }

$utf8 = New-Object System.Text.UTF8Encoding($false)
$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8)
$stdout = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$stdout.AutoFlush = $true

$script:models = @()
$script:savedModels = @()
$script:loaded = $false
$script:busy = $false
$script:rendering = $false
$script:selectedIndex = -1
$script:currentVersion = ""
$script:latestVersion = $null
$script:releaseUrl = $null
$script:checkingUpdate = $false
$script:quitting = $false

function Send-Request([hashtable]$Request) {
  $stdout.WriteLine(($Request | ConvertTo-Json -Compress -Depth 6))
}

function Convert-Context([int]$k) {
  if ($k -lt 1000) { return "${k}k" }
  if ($k % 1000 -eq 0) { return "$([int]($k / 1000))M" }
  $fraction = ([string]($k % 1000)).PadLeft(3, "0").TrimEnd("0")
  return "$([int]($k / 1000)).${fraction}M"
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GPT Switch" Height="560" Width="780" MinHeight="460" MinWidth="660"
        Background="#FDFDFD" FontFamily="Segoe UI" FontSize="12"
        WindowStartupLocation="CenterScreen" SnapsToDevicePixels="True" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="Background" Value="#EDEDEE"/>
      <Setter Property="Foreground" Value="#212327"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="fill" Background="{TemplateBinding Background}" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="fill" Property="Opacity" Value="0.82"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="fill" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PillPrimary" TargetType="Button" BasedOn="{StaticResource Pill}">
      <Setter Property="Background" Value="#212327"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="PillIcon" TargetType="Button" BasedOn="{StaticResource Pill}">
      <Setter Property="Width" Value="32"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#656667"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="4,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#212327"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Cell" TargetType="TextBox">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#212327"/>
      <Setter Property="CaretBrush" Value="#212327"/>
    </Style>
  </Window.Resources>
  <Grid Margin="20,18,20,18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="0,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Text="模型配置" FontSize="20" FontWeight="SemiBold" Foreground="#212327"/>
        <TextBlock Text="自定义模型 ID 与上下文窗口，保存并重启后在新任务中生效"
                   FontSize="12" Foreground="#656667" Margin="0,4,0,0"/>
      </StackPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="AddButton" Style="{StaticResource PillIcon}" Content="+" ToolTip="添加模型" Margin="0,0,6,0"/>
        <Button x:Name="RemoveButton" Style="{StaticResource PillIcon}" Content="-" ToolTip="删除选中模型"/>
      </StackPanel>
    </Grid>

    <Border Grid.Row="1" Background="#FFFFFF" BorderBrush="#EDEDEE" BorderThickness="1" CornerRadius="12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" BorderBrush="#EDEDEE" BorderThickness="0,0,0,1" Padding="12,8">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="128"/>
              <ColumnDefinition Width="96"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="模型 ID" FontSize="12" Foreground="#656667"/>
            <TextBlock Grid.Column="1" Text="上下文窗口" FontSize="12" Foreground="#656667" HorizontalAlignment="Right"/>
            <TextBlock Grid.Column="2" Text="会话大小" FontSize="12" Foreground="#656667" HorizontalAlignment="Right"/>
          </Grid>
        </Border>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="0,4,0,4">
          <StackPanel x:Name="RowsPanel"/>
        </ScrollViewer>
        <StackPanel x:Name="EmptyState" Grid.Row="1" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed">
          <TextBlock Text="暂无自定义模型" FontSize="13" Foreground="#212327" HorizontalAlignment="Center"/>
          <TextBlock Text="点击右上角 + 添加模型，例如 gpt-6-astra" FontSize="11" Foreground="#88898A"
                     HorizontalAlignment="Center" Margin="0,6,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <Grid Grid.Row="2" Margin="0,10,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="窗口单位 k：1000k = 1M，保存后需重启 ChatGPT/Codex 才生效"
                 FontSize="11" Foreground="#88898A" VerticalAlignment="Center"/>
      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock x:Name="VersionLabel" FontSize="11" Foreground="#88898A" VerticalAlignment="Center"/>
        <Button x:Name="UpdateButton" Style="{StaticResource Link}" Content="检查更新" Margin="8,0,0,0"/>
      </StackPanel>
    </Grid>

    <Grid Grid.Row="3" Margin="0,12,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="Feedback" Grid.Column="0" FontSize="12" Foreground="#656667"
                 TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,12,0"/>
      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="ClearButton" Style="{StaticResource Pill}" Content="清空并重启" Margin="0,0,8,0"/>
        <Button x:Name="SaveButton" Style="{StaticResource Pill}" Content="保存" Margin="0,0,8,0"/>
        <Button x:Name="RestartButton" Style="{StaticResource PillPrimary}" Content="保存并重启 ChatGPT"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$addButton = $window.FindName("AddButton")
$removeButton = $window.FindName("RemoveButton")
$clearButton = $window.FindName("ClearButton")
$saveButton = $window.FindName("SaveButton")
$restartButton = $window.FindName("RestartButton")
$updateButton = $window.FindName("UpdateButton")
$versionLabel = $window.FindName("VersionLabel")
$feedback = $window.FindName("Feedback")
$rowsPanel = $window.FindName("RowsPanel")
$emptyState = $window.FindName("EmptyState")

# 面板跑在 powershell.exe 里，不显式设置就会顶着 PowerShell 的图标。
# sips 生成的 ico 是 PNG 压缩的，先走 WIC 解码，失败再退回 System.Drawing。
function Get-PanelIconBitmap {
  if (-not $IconPath -or -not (Test-Path -LiteralPath $IconPath)) { return $null }
  try {
    $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$IconPath)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add($frame)
    $stream = New-Object System.IO.MemoryStream
    $encoder.Save($stream)
    $stream.Position = 0
    $bitmap = New-Object System.Drawing.Bitmap($stream)
    $stream.Dispose()
    return $bitmap
  } catch {
    try { return (New-Object System.Drawing.Icon($IconPath)).ToBitmap() } catch { return $null }
  }
}

function Set-PanelIcon {
  $bitmap = Get-PanelIconBitmap
  if (-not $bitmap) { return }
  try {
    $handle = $bitmap.GetHbitmap()
    try {
      $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
        $handle,
        [IntPtr]::Zero,
        [System.Windows.Int32Rect]::Empty,
        [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
      $source.Freeze()
      $window.Icon = $source
    } finally {
      [void][GPTSwitch.Native]::DeleteObject($handle)
    }
  } catch { } finally {
    $bitmap.Dispose()
  }
}

Set-PanelIcon

function Set-Feedback([string]$Text, [bool]$IsError = $false) {
  $feedback.Text = $Text
  $feedback.Foreground = if ($IsError) { "#D93025" } else { "#656667" }
}

function Update-Controls {
  $addButton.IsEnabled = $script:loaded -and -not $script:busy
  $removeButton.IsEnabled = $script:loaded -and -not $script:busy -and $script:selectedIndex -ge 0 -and $script:selectedIndex -lt $script:models.Count
  $clearButton.IsEnabled = $script:loaded -and -not $script:busy
  $restartButton.IsEnabled = $script:loaded -and -not $script:busy
  $saveButton.IsEnabled = $script:loaded -and -not $script:busy -and (Compare-Models $script:models $script:savedModels)
  $emptyState.Visibility = if ($script:loaded -and $script:models.Count -eq 0) { "Visible" } else { "Collapsed" }
}

function Compare-Models($Left, $Right) {
  if ($Left.Count -ne $Right.Count) { return $true }
  for ($index = 0; $index -lt $Left.Count; $index++) {
    if ($Left[$index].id -ne $Right[$index].id) { return $true }
    if ($Left[$index].context -ne $Right[$index].context) { return $true }
  }
  return $false
}

function Select-Row([int]$Index) {
  $script:selectedIndex = $Index
  $rows = $rowsPanel.Children
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $rows[$i].Background = if ($i -eq $Index) { "#F1F1F3" } else { "#00FFFFFF" }
  }
  Update-Controls
}

function Rebuild-Rows {
  $script:rendering = $true
  $rowsPanel.Children.Clear()
  for ($index = 0; $index -lt $script:models.Count; $index++) {
    $model = $script:models[$index]
    $border = New-Object System.Windows.Controls.Border
    $border.BorderThickness = "0,0,0,1"
    $border.BorderBrush = "#EDEDEE"
    $border.Background = "#00FFFFFF"
    $border.Padding = "12,0"
    $border.Height = 40
    $border.Tag = $index

    $grid = New-Object System.Windows.Controls.Grid
    foreach ($width in @("*", "128", "96")) {
      $column = New-Object System.Windows.Controls.ColumnDefinition
      $column.Width = [System.Windows.GridLength]::new([double]($width -replace '\*', '1'), $(if ($width -eq "*") { "Star" } else { "Pixel" }))
      $grid.ColumnDefinitions.Add($column)
    }

    $idBox = New-Object System.Windows.Controls.TextBox
    $idBox.Style = $window.FindResource("Cell")
    $idBox.Text = [string]$model.id
    $idBox.Tag = $index
    $idBox.IsEnabled = $script:loaded -and -not $script:busy
    $idBox.VerticalAlignment = "Center"
    $idBox.Add_TextChanged({ param($sender, $eventArgs) Update-Model $sender "id" })
    $idBox.Add_GotFocus({ param($sender, $eventArgs) Select-Row ([int]$sender.Tag) })

    $contextBox = New-Object System.Windows.Controls.TextBox
    $contextBox.Style = $window.FindResource("Cell")
    $contextBox.Text = [string]$model.context
    $contextBox.Tag = $index
    $contextBox.IsEnabled = $script:loaded -and -not $script:busy
    $contextBox.TextAlignment = "Right"
    $contextBox.VerticalAlignment = "Center"
    $contextBox.Add_TextChanged({ param($sender, $eventArgs) Update-Model $sender "context" })
    $contextBox.Add_GotFocus({ param($sender, $eventArgs) Select-Row ([int]$sender.Tag) })

    $converted = New-Object System.Windows.Controls.TextBlock
    $converted.Text = Convert-Context ([int]$model.context)
    $converted.FontFamily = "Consolas"
    $converted.FontSize = 12
    $converted.Foreground = "#656667"
    $converted.HorizontalAlignment = "Right"
    $converted.VerticalAlignment = "Center"

    [System.Windows.Controls.Grid]::SetColumn($idBox, 0)
    [System.Windows.Controls.Grid]::SetColumn($contextBox, 1)
    [System.Windows.Controls.Grid]::SetColumn($converted, 2)
    [void]$grid.Children.Add($idBox)
    [void]$grid.Children.Add($contextBox)
    [void]$grid.Children.Add($converted)
    $border.Child = $grid
    [void]$rowsPanel.Children.Add($border)
  }
  $script:rendering = $false
  Select-Row $script:selectedIndex
}

function Update-Model($Sender, [string]$Field) {
  if ($script:rendering -or $script:busy) { return }
  $index = [int]$Sender.Tag
  if ($index -lt 0 -or $index -ge $script:models.Count) { return }
  if ($Field -eq "id") {
    $script:models[$index].id = $Sender.Text
  } else {
    $value = 0
    if ([int]::TryParse($Sender.Text.Trim(), [ref]$value) -and $value -ge 1) {
      $script:models[$index].context = $value
      $row = $rowsPanel.Children[$index]
      $row.Child.Children[2].Text = Convert-Context $value
    }
  }
  Set-Feedback $(if (Compare-Models $script:models $script:savedModels) { "有未保存的更改" } else { "" })
  Update-Controls
}

function Receive-Response($Response) {
  if ($Response.version -and $Response.version -ne $script:currentVersion) {
    $script:currentVersion = [string]$Response.version
    Refresh-VersionLabel
  }
  if ($script:checkingUpdate) {
    Finish-UpdateCheck $Response
    return
  }
  $script:busy = $false
  $ok = $Response.ok -eq $true
  $cleared = $Response.cleared -eq $true
  if ($ok -or $Response.saved -eq $true -or $cleared) {
    if ($null -ne $Response.models) {
      $script:models = @($Response.models | ForEach-Object { @{ id = [string]$_.id; context = [int]$_.context } })
      $script:savedModels = @($script:models | ForEach-Object { @{ id = $_.id; context = $_.context } })
      $script:loaded = $true
      $script:selectedIndex = -1
      Rebuild-Rows
    }
  }
  if (-not $ok) {
    Set-Feedback $(if ($Response.error) { [string]$Response.error } else { "操作失败" }) $true
  } elseif ($cleared) {
    Set-Feedback "已清空并重启 ChatGPT"
  } elseif ($Response.restarted -eq $true) {
    Set-Feedback "已保存，ChatGPT 已重启"
  } elseif ($Response.saved -eq $true) {
    Set-Feedback "已保存，点击“保存并重启 ChatGPT”后生效"
  } else {
    Set-Feedback ""
  }
  Update-Controls
}

function Refresh-VersionLabel([string]$Suffix = "") {
  if (-not $script:currentVersion) { return }
  $versionLabel.Text = if ($Suffix) { "v$($script:currentVersion) · $Suffix" } else { "v$($script:currentVersion)" }
}

function Test-VersionNewer([string]$Candidate, [string]$Base) {
  $left = @($Candidate -replace "v", "" -split "\." | ForEach-Object { [int]($_ -replace "\D", "") })
  $right = @($Base -replace "v", "" -split "\." | ForEach-Object { [int]($_ -replace "\D", "") })
  for ($index = 0; $index -lt [Math]::Max($left.Count, $right.Count); $index++) {
    $a = if ($index -lt $left.Count) { $left[$index] } else { 0 }
    $b = if ($index -lt $right.Count) { $right[$index] } else { 0 }
    if ($a -ne $b) { return $a -gt $b }
  }
  return $false
}

function Finish-UpdateCheck($Response) {
  $script:checkingUpdate = $false
  if ($Response.ok -ne $true -or -not $Response.latest) {
    Refresh-VersionLabel "检查更新失败"
    $updateButton.Content = "重试"
    $updateButton.IsEnabled = $true
    return
  }
  $latest = [string]$Response.latest
  if (Test-VersionNewer $latest $script:currentVersion) {
    $script:latestVersion = $latest
    $script:releaseUrl = [string]$Response.url
    Refresh-VersionLabel "有新版本 v$latest"
    $updateButton.Content = "去下载"
  } else {
    $script:latestVersion = $null
    $script:releaseUrl = $null
    Refresh-VersionLabel "已是最新"
    $updateButton.Content = "检查更新"
  }
  $updateButton.IsEnabled = $true
}

function Submit([bool]$Restart) {
  if (-not $script:loaded -or $script:busy) { return }
  $script:busy = $true
  Set-Feedback $(if ($Restart) { "正在保存并重启 ChatGPT…" } else { "正在保存…" })
  Rebuild-Rows
  Update-Controls
  Send-Request @{
    action = "save"
    restart = $Restart
    models = @($script:models | ForEach-Object { @{ id = $_.id; context = $_.context } })
  }
}

$addButton.Add_Click({
  if (-not $script:loaded -or $script:busy) { return }
  $script:models = @($script:models) + @{ id = ""; context = 272 }
  $script:selectedIndex = $script:models.Count - 1
  Rebuild-Rows
  Set-Feedback "有未保存的更改"
  Update-Controls
  $rowsPanel.Children[$script:selectedIndex].Child.Children[0].Focus() | Out-Null
})

$removeButton.Add_Click({
  if ($script:busy) { return }
  if ($script:selectedIndex -lt 0 -or $script:selectedIndex -ge $script:models.Count) { return }
  $remaining = @()
  for ($index = 0; $index -lt $script:models.Count; $index++) {
    if ($index -ne $script:selectedIndex) { $remaining += $script:models[$index] }
  }
  $script:models = $remaining
  $script:selectedIndex = -1
  Rebuild-Rows
  Set-Feedback $(if (Compare-Models $script:models $script:savedModels) { "有未保存的更改" } else { "" })
  Update-Controls
})

$saveButton.Add_Click({ Submit $false })
$restartButton.Add_Click({ Submit $true })

$clearButton.Add_Click({
  if (-not $script:loaded -or $script:busy) { return }
  $answer = [System.Windows.MessageBox]::Show(
    $window,
    "将删除插件保存的模型配置，并清理写入 Codex 的模型目录和 model_catalog_json 配置。",
    "清空自定义模型并重启 ChatGPT？",
    "OKCancel", "Warning")
  if ($answer -ne "OK") { return }
  $script:busy = $true
  Set-Feedback "正在清空并重启 ChatGPT…"
  Rebuild-Rows
  Update-Controls
  Send-Request @{ action = "clear" }
})

$updateButton.Add_Click({
  if ($script:latestVersion -and $script:releaseUrl) {
    Start-Process $script:releaseUrl
    return
  }
  if ($script:checkingUpdate) { return }
  $script:checkingUpdate = $true
  $updateButton.Content = "检查中…"
  $updateButton.IsEnabled = $false
  Send-Request @{ action = "check-update" }
})

$window.Add_Closing({
  param($sender, $eventArgs)
  if ($script:quitting) { return }
  # 关窗只是收起面板：最小化到任务栏，插件继续在托盘运行。
  # 不用 Hide()：WPF 隐藏后自己不再渲染，被外部 ShowWindow 叫回来会是一片黑。
  $eventArgs.Cancel = $true
  $sender.WindowState = "Minimized"
})

# 面板由后台进程拉起，需要主动抢一次前台，否则会藏在其他窗口后面。
$window.Add_Loaded({
  $window.Activate() | Out-Null
  $window.Topmost = $true
  $window.Topmost = $false
})

# ---- 托盘图标：打开面板 / 退出 ----
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = "GPT Switch"
$tray.Visible = $true
$tray.Icon = [System.Drawing.SystemIcons]::Application
$trayBitmap = Get-PanelIconBitmap
if ($trayBitmap) {
  try { $tray.Icon = [System.Drawing.Icon]::FromHandle($trayBitmap.GetHicon()) } catch { }
}
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add("打开面板")
$quitItem = $menu.Items.Add("退出")
$tray.ContextMenuStrip = $menu

$showPanel = {
  $window.Show()
  $window.WindowState = "Normal"
  $window.Activate() | Out-Null
  $handle = [GPTSwitch.Native]::FindWindowW([NullString]::Value, "GPT Switch")
  if ($handle -and $handle -ne [IntPtr]::Zero) { [void][GPTSwitch.Native]::SetForegroundWindow($handle) }
}

$openItem.Add_Click($showPanel)
$tray.Add_MouseDoubleClick($showPanel)

$quitItem.Add_Click({
  $script:quitting = $true
  Send-Request @{ action = "quit" }
  $tray.Visible = $false
  $window.Dispatcher.InvokeAsync({ $window.Close(); [System.Windows.Application]::Current.Shutdown() }) | Out-Null
})

# ---- 与注入器的 stdio 循环 ----
$script:readTask = $stdin.ReadLineAsync()
$readTimer = New-Object System.Windows.Threading.DispatcherTimer
$readTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$readTimer.Add_Tick({
  if (-not $script:readTask.IsCompleted) { return }
  $line = $null
  try { $line = $script:readTask.Result } catch { $line = $null }
  if ($null -eq $line) {
    $tray.Visible = $false
    [System.Windows.Application]::Current.Shutdown()
    return
  }
  $script:readTask = $stdin.ReadLineAsync()
  if (-not $line.Trim()) { return }
  try {
    $response = $line | ConvertFrom-Json
  } catch {
    return
  }
  if ($response.command -eq "show") { & $showPanel; return }
  try {
    Receive-Response $response
  } catch {
    Set-Feedback "处理插件响应失败：$($_.Exception.Message)" $true
  }
})
$readTimer.Start()

$parentTimer = New-Object System.Windows.Threading.DispatcherTimer
$parentTimer.Interval = [TimeSpan]::FromSeconds(1)
$parentTimer.Add_Tick({
  if ($ParentPid -le 1) { return }
  $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
  if (-not $parent) {
    $tray.Visible = $false
    [System.Windows.Application]::Current.Shutdown()
  }
})
$parentTimer.Start()

$application = New-Object System.Windows.Application
$application.ShutdownMode = "OnExplicitShutdown"
# 系统注销/关机时不要再拦关闭。
$application.Add_SessionEnding({ $script:quitting = $true })
Set-Feedback "正在读取配置…"
$script:busy = $true
Update-Controls
Send-Request @{ action = "load" }
# 启动期用 Stop 尽早暴露问题；跑起来之后用 Continue，避免偶发异常把面板整个关掉。
$ErrorActionPreference = "Continue"
[void]$application.Run($window)
$tray.Visible = $false
$tray.Dispose()
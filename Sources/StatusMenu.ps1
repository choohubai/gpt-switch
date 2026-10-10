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
[DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr owner);
[DllImport("user32.dll")] public static extern bool CloseClipboard();
[DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint format);
[DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr handle);
[DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr handle);
'@

try { [void][GPTSwitch.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) }
catch { try { [void][GPTSwitch.Native]::SetProcessDPIAware() } catch { } }

# 让任务栏把面板当成独立应用，而不是 PowerShell 的一个窗口。
try { [void][GPTSwitch.Native]::SetCurrentProcessExplicitAppUserModelID("choohubai.GPTSwitch") } catch { }

$utf8 = New-Object System.Text.UTF8Encoding($false)
$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8)
$stdout = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$stdout.AutoFlush = $true

$script:channels = @()
$script:savedChannels = @()
$script:channelIndex = -1
$script:currentChannelId = ""
$script:loaded = $false
$script:busy = $false
$script:rendering = $false
$script:currentVersion = ""
$script:latestVersion = $null
$script:releaseUrl = $null
$script:checkingUpdate = $false
$script:quitting = $false
$script:pendingDeleteRestore = $null
$script:pendingDeleteNote = ""
$script:deleteKind = ""
$script:deleteIndex = -1
$script:fetchingModels = $false
$script:discoveredModels = @()
$script:discoveredSelection = @{}
$script:discovering = $false

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
        Title="GPT Switch" Height="700" Width="860" MinHeight="600" MinWidth="760"
        Background="#FFFFFF" FontFamily="Segoe UI" FontSize="13"
        WindowStartupLocation="CenterScreen" SnapsToDevicePixels="True" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#212327"/>
      <Setter Property="BorderBrush" Value="#E8E8EB"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="fill" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="7">
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
      <Setter Property="Background" Value="#F4F4F5"/>
      <Setter Property="Foreground" Value="#212327"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="PillDanger" TargetType="Button" BasedOn="{StaticResource Pill}">
      <Setter Property="Foreground" Value="#D93025"/>
    </Style>
    <Style x:Key="DangerOutline" TargetType="Button" BasedOn="{StaticResource Pill}">
      <Setter Property="Background" Value="#FDF2F2"/>
      <Setter Property="BorderBrush" Value="#E79A94"/>
      <Setter Property="Foreground" Value="#D93025"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="Padding" Value="22,0"/>
    </Style>
    <Style x:Key="Dashed" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#656667"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Height" Value="46"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Rectangle RadiusX="8" RadiusY="8" Stroke="#D8D8DC" StrokeThickness="1" StrokeDashArray="3 2"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
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
      <Setter Property="FontSize" Value="12"/>
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
    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Height" Value="38"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="frame" Background="{TemplateBinding Background}"
                    BorderBrush="#E0E0E3" BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="frame" Property="BorderBrush" Value="#8AB4F8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="frame" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SecretField" TargetType="PasswordBox">
      <Setter Property="Height" Value="38"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="frame" Background="{TemplateBinding Background}"
                    BorderBrush="#E0E0E3" BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="frame" Property="BorderBrush" Value="#8AB4F8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="frame" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#E8E8EB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
    </Style>
  </Window.Resources>
  <Grid Margin="20,18,20,18">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid x:Name="ListPage" Grid.Row="0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid Grid.Row="0" Margin="0,0,0,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="渠道" FontSize="20" FontWeight="SemiBold" Foreground="#212327"/>
          <TextBlock Text="点「启用」立即写进 ChatGPT 配置并重启；点右侧编辑图标改配置"
                     FontSize="13" Foreground="#656667" Margin="0,4,0,0"/>
        </StackPanel>
        <Button x:Name="ClearButton" Grid.Column="1" Style="{StaticResource Link}" Content="还原 ChatGPT 配置并重启"
                VerticalAlignment="Top"/>
      </Grid>
      <Border Grid.Row="1" Background="#FFFFFF" BorderBrush="#E8E8EB" BorderThickness="1" CornerRadius="12">
        <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" Padding="18,16,18,16">
            <StackPanel x:Name="ChannelPanel"/>
          </ScrollViewer>
          <StackPanel x:Name="ChannelEmpty" Grid.Row="0" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed">
            <TextBlock Text="还没有渠道" FontSize="14" Foreground="#212327" HorizontalAlignment="Center"/>
            <TextBlock Text="点下面的“添加渠道”填地址、密钥和模型" FontSize="12" Foreground="#88898A"
                       HorizontalAlignment="Center" Margin="0,6,0,0"/>
          </StackPanel>
          <!-- 「添加渠道」按 cc-switch 的做法做成列表里最后一行。 -->
          <Button x:Name="AddChannelButton" Grid.Row="1" Style="{StaticResource Dashed}" Content="添加渠道" Margin="14,0,14,14"/>
        </Grid>
      </Border>
    </Grid>

    <Grid x:Name="DetailPage" Grid.Row="0" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid Grid.Row="0" Margin="0,0,0,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="BackButton" Grid.Column="0" Style="{StaticResource Link}" Content="‹ 返回"/>
        <TextBlock x:Name="PageTitle" Grid.Column="1" Text="添加渠道" FontSize="16" FontWeight="SemiBold"
                   Foreground="#212327" VerticalAlignment="Center" Margin="8,0,0,0"/>
        <Button x:Name="DeleteChannelButton" Grid.Column="3" Style="{StaticResource PillDanger}" Content="删除渠道"/>
      </Grid>
      <Border Grid.Row="1" Background="#FFFFFF" BorderBrush="#E4E4E7" BorderThickness="1" CornerRadius="12" Padding="16,14">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Grid.Column="0" Text="渠道 ID" FontSize="13" FontWeight="Medium" Foreground="#656667"/>
          <TextBox x:Name="ChannelIdField" Grid.Row="1" Grid.Column="0" Style="{StaticResource Field}" Width="240" HorizontalAlignment="Left" Margin="0,4,16,0"/>
          <TextBlock Grid.Row="0" Grid.Column="2" Text="API 密钥" FontSize="13" FontWeight="Medium" Foreground="#656667"/>
          <PasswordBox x:Name="ChannelApiKeyField" Grid.Row="1" Grid.Column="2" Style="{StaticResource SecretField}" Width="240" HorizontalAlignment="Left" Margin="0,4,0,0"/>
          <TextBlock Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="4" Text="API 地址" FontSize="13" FontWeight="Medium" Foreground="#656667" Margin="0,14,0,0"/>
          <TextBox x:Name="ChannelBaseUrlField" Grid.Row="3" Grid.Column="0" Grid.ColumnSpan="4" Style="{StaticResource Field}" HorizontalAlignment="Stretch" Margin="0,4,0,0"/>
        </Grid>
      </Border>
      <StackPanel Grid.Row="2" Margin="0,12,0,8">
        <TextBlock Text="额外请求头（可选）" FontSize="13" FontWeight="Medium" Foreground="#656667"/>
        <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
          <TextBox x:Name="ChannelHeaderNameField" Style="{StaticResource Field}" Width="220"/>
          <TextBox x:Name="ChannelHeaderValueField" Style="{StaticResource Field}" Width="300" Margin="8,0,0,0"/>
        </StackPanel>
        <TextBlock Text="需要自定义请求头的中转才填，留空则不加" FontSize="12" Foreground="#88898A" Margin="0,4,0,0"/>
      </StackPanel>
      <Grid Grid.Row="3" Margin="0,0,0,8">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="模型目录" FontSize="14" FontWeight="SemiBold" Foreground="#212327" VerticalAlignment="Center"/>
        <Button x:Name="FetchModelsButton" Grid.Column="1" Style="{StaticResource Link}" Content="获取可用模型" VerticalAlignment="Center"/>
      </Grid>
      <Border Grid.Row="4" Style="{StaticResource Card}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" Padding="18,16,18,4">
            <StackPanel x:Name="RowsPanel"/>
          </ScrollViewer>
          <StackPanel x:Name="EmptyState" Grid.Row="0" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed">
            <TextBlock Text="暂无自定义模型" FontSize="14" Foreground="#212327" HorizontalAlignment="Center"/>
            <TextBlock Text="点下面的「添加模型」，例如 gpt-6-astra" FontSize="12" Foreground="#88898A"
                       HorizontalAlignment="Center" Margin="0,6,0,0"/>
          </StackPanel>
          <Border Grid.Row="1" BorderBrush="#E8E8EB" BorderThickness="0,1,0,0"/>
          <Button x:Name="AddModelButton" Grid.Row="2" Style="{StaticResource Dashed}" Content="＋ 添加模型"
                  HorizontalAlignment="Left" Width="120" Margin="14,10,14,12"/>
        </Grid>
      </Border>
      <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
        <Button x:Name="SaveButton" Style="{StaticResource Pill}" Content="保存"/>
      </StackPanel>
    </Grid>

    <Grid Grid.Row="1" Margin="0,12,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="Feedback" Grid.Column="0" FontSize="13" Foreground="#656667"
                 TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,12,0"/>
      <TextBlock x:Name="VersionLabel" Grid.Column="2" FontSize="12" Foreground="#88898A" VerticalAlignment="Center"/>
      <Button x:Name="UpdateButton" Grid.Column="3" Style="{StaticResource Link}" Content="检查更新" Margin="8,0,0,0"/>
    </Grid>

    <!-- 删除统一先走这张卡片：确认后才真正删。负边距把遮罩铺到窗口边缘。 -->
    <Grid x:Name="ConfirmLayer" Grid.Row="0" Grid.RowSpan="2" Margin="-20,-18,-20,-18"
          Background="#1F000000" Visibility="Collapsed">
      <Border Width="460" HorizontalAlignment="Center" VerticalAlignment="Center"
              Background="#FFFFFF" CornerRadius="14" Padding="24" BorderBrush="#22000000" BorderThickness="1">
        <Border.Effect>
          <DropShadowEffect BlurRadius="24" ShadowDepth="6" Direction="270" Opacity="0.18" Color="#000000"/>
        </Border.Effect>
        <StackPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="ConfirmTitle" Grid.Column="0" FontSize="17" FontWeight="SemiBold"
                       Foreground="#212327" TextWrapping="Wrap" VerticalAlignment="Center"/>
            <Button x:Name="ConfirmClose" Grid.Column="1" Style="{StaticResource Link}" Content="✕" FontSize="13"
                    VerticalAlignment="Top" Margin="8,0,0,0"/>
          </Grid>
          <TextBlock x:Name="ConfirmMessage" FontSize="14" Foreground="#656667" TextWrapping="Wrap" Margin="0,14,0,0"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
            <Button x:Name="ConfirmCancel" Style="{StaticResource Pill}" Content="取消" Height="38" Padding="22,0"/>
            <Button x:Name="ConfirmDelete" Style="{StaticResource DangerOutline}" Content="删除" Margin="10,0,0,0"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>
    <!-- 端点清单先在这里勾选，点「添加所选」才进模型目录。 -->
    <Grid x:Name="DiscoverLayer" Grid.Row="0" Grid.RowSpan="2" Margin="-20,-18,-20,-18"
          Background="#1F000000" Visibility="Collapsed">
      <Border Width="460" HorizontalAlignment="Center" VerticalAlignment="Center"
              Background="#FFFFFF" CornerRadius="14" Padding="24" BorderBrush="#22000000" BorderThickness="1">
        <Border.Effect>
          <DropShadowEffect BlurRadius="24" ShadowDepth="6" Direction="270" Opacity="0.18" Color="#000000"/>
        </Border.Effect>
        <StackPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="选择要添加的模型" FontSize="17" FontWeight="SemiBold"
                       Foreground="#212327" VerticalAlignment="Center"/>
            <Button x:Name="DiscoverClose" Grid.Column="1" Style="{StaticResource Link}" Content="✕" FontSize="13"
                    VerticalAlignment="Top" Margin="8,0,0,0"/>
          </Grid>
          <TextBlock Text="以下是模型提供商的可用模型，勾选要添加的模型。" FontSize="13" Foreground="#656667"
                     TextWrapping="Wrap" Margin="0,12,0,0"/>
          <Grid Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid Grid.Column="0">
              <TextBox x:Name="DiscoverSearch" Style="{StaticResource Field}" Height="32"/>
              <TextBlock x:Name="DiscoverHint" Text="搜索模型" FontSize="13" Foreground="#9A9B9D"
                         VerticalAlignment="Center" Margin="13,0,0,0" IsHitTestVisible="False"/>
            </Grid>
            <CheckBox x:Name="DiscoverSelectAll" Grid.Column="1" Content="全选" FontSize="13" Margin="14,0,0,0"
                      VerticalAlignment="Center"/>
          </Grid>
          <Border BorderBrush="#E8E8EB" BorderThickness="0,1,0,0" Margin="0,14,0,0"/>
          <ScrollViewer Height="200" VerticalScrollBarVisibility="Auto" Margin="0,10,0,0">
            <StackPanel x:Name="DiscoverList"/>
          </ScrollViewer>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
            <Button x:Name="DiscoverCancel" Style="{StaticResource Pill}" Content="取消" Height="38" Padding="22,0"/>
            <Button x:Name="DiscoverAdd" Style="{StaticResource Pill}" Content="添加所选" Height="38" Padding="22,0"
                    Margin="10,0,0,0"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>

</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$addButton = $window.FindName("AddModelButton")
$clearButton = $window.FindName("ClearButton")
$saveButton = $window.FindName("SaveButton")
$updateButton = $window.FindName("UpdateButton")
$versionLabel = $window.FindName("VersionLabel")
$feedback = $window.FindName("Feedback")
$rowsPanel = $window.FindName("RowsPanel")
$emptyState = $window.FindName("EmptyState")
$listPage = $window.FindName("ListPage")
$detailPage = $window.FindName("DetailPage")
$channelPanel = $window.FindName("ChannelPanel")
$channelEmpty = $window.FindName("ChannelEmpty")
$addChannelButton = $window.FindName("AddChannelButton")
$backButton = $window.FindName("BackButton")
$pageTitle = $window.FindName("PageTitle")
$deleteChannelButton = $window.FindName("DeleteChannelButton")
$channelIdField = $window.FindName("ChannelIdField")
$channelBaseUrlField = $window.FindName("ChannelBaseUrlField")
$channelApiKeyField = $window.FindName("ChannelApiKeyField")
$channelHeaderNameField = $window.FindName("ChannelHeaderNameField")
$channelHeaderValueField = $window.FindName("ChannelHeaderValueField")
$confirmLayer = $window.FindName("ConfirmLayer")
$confirmTitle = $window.FindName("ConfirmTitle")
$confirmMessage = $window.FindName("ConfirmMessage")
$confirmClose = $window.FindName("ConfirmClose")
$confirmCancel = $window.FindName("ConfirmCancel")
$confirmDelete = $window.FindName("ConfirmDelete")
$fetchModelsButton = $window.FindName("FetchModelsButton")
$discoverLayer = $window.FindName("DiscoverLayer")
$discoverSearch = $window.FindName("DiscoverSearch")
$discoverHint = $window.FindName("DiscoverHint")
$discoverSelectAll = $window.FindName("DiscoverSelectAll")
$discoverList = $window.FindName("DiscoverList")
$discoverClose = $window.FindName("DiscoverClose")
$discoverCancel = $window.FindName("DiscoverCancel")
$discoverAdd = $window.FindName("DiscoverAdd")

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

function Get-ActiveChannel {
  if ($script:channelIndex -ge 0 -and $script:channelIndex -lt $script:channels.Count) {
    return $script:channels[$script:channelIndex]
  }
  return $null
}

function Get-ActiveModels {
  $channel = Get-ActiveChannel
  if ($channel) { return @($channel.models) }
  return @()
}

function Update-ChannelFields {
  $channel = Get-ActiveChannel
  $script:rendering = $true
  try {
    $channelIdField.Text = if ($channel) { [string]$channel.id } else { "" }
    $channelBaseUrlField.Text = if ($channel) { [string]$channel.baseUrl } else { "" }
    $channelApiKeyField.Password = if ($channel) { [string]$channel.apiKey } else { "" }
    $channelHeaderNameField.Text = if ($channel) { [string]$channel.headerName } else { "" }
    $channelHeaderValueField.Text = if ($channel) { [string]$channel.headerValue } else { "" }
    $pageTitle.Text = if ($channel -and -not [string]::IsNullOrWhiteSpace([string]$channel.id)) { [string]$channel.id } else { "添加渠道" }
  } finally {
    $script:rendering = $false
  }
}

function Update-ChannelList {
  $script:rendering = $true
  try {
    $channelPanel.Children.Clear()
    for ($index = 0; $index -lt $script:channels.Count; $index++) {
      $channel = $script:channels[$index]
      $isCurrent = $script:currentChannelId -and [string]$channel.id -eq $script:currentChannelId
      $border = New-Object System.Windows.Controls.Border
      $border.BorderThickness = "1"
      $border.BorderBrush = if ($isCurrent) { "#212327" } else { "#E4E4E7" }
      $border.Background = if ($isCurrent) { "#F4F4F5" } else { "#FFFFFF" }
      $border.CornerRadius = "12"
      $border.Padding = "18,0"
      $border.Margin = "0,0,0,10"
      $border.Height = 66
      $border.Tag = $index

      $grid = New-Object System.Windows.Controls.Grid
      foreach ($width in @("*", "Auto", "Auto", "Auto")) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        $column.Width = if ($width -eq "*") { [System.Windows.GridLength]::new(1, "Star") } else { [System.Windows.GridLength]::new(0, "Auto") }
        $grid.ColumnDefinitions.Add($column)
      }

      $texts = New-Object System.Windows.Controls.StackPanel
      $texts.VerticalAlignment = "Center"
      $idText = New-Object System.Windows.Controls.TextBlock
      $idText.Text = if ([string]::IsNullOrWhiteSpace([string]$channel.id)) { "未填渠道 ID" } else { [string]$channel.id }
      $idText.FontFamily = "Consolas"
      $idText.FontSize = 14
      $idText.FontWeight = "SemiBold"
      $idText.Foreground = "#212327"
      $idText.TextTrimming = "CharacterEllipsis"
      $urlText = New-Object System.Windows.Controls.TextBlock
      $urlText.Text = if ([string]::IsNullOrWhiteSpace([string]$channel.baseUrl)) { "还没填地址" } else { [string]$channel.baseUrl }
      $urlText.FontSize = 12
      $urlText.Foreground = "#656667"
      $urlText.TextTrimming = "CharacterEllipsis"
      [void]$texts.Children.Add($idText)
      [void]$texts.Children.Add($urlText)

      # 当前渠道显示状态文字，其余渠道给「启用」按钮，直接在首页启用。
      $trailing = New-Object System.Windows.Controls.StackPanel
      $trailing.Orientation = "Horizontal"
      $trailing.VerticalAlignment = "Center"
      if ($isCurrent) {
        $dot = New-Object System.Windows.Controls.Ellipse
        $dot.Width = 6
        $dot.Height = 6
        $dot.Fill = "#212327"
        $dot.Margin = "0,0,6,0"
        $dot.VerticalAlignment = "Center"
        $statusText = New-Object System.Windows.Controls.TextBlock
        $statusText.Text = "使用中"
        $statusText.FontSize = 13
        $statusText.FontWeight = "Medium"
        $statusText.Foreground = "#212327"
        $statusText.VerticalAlignment = "Center"
        [void]$trailing.Children.Add($dot)
        [void]$trailing.Children.Add($statusText)
      } else {
        $switchButton = New-Object System.Windows.Controls.Button
        $switchButton.Style = $window.FindResource("Pill")
        $switchButton.Content = "启用"
        $switchButton.Tag = $index
        $switchButton.Add_Click({
          param($sender, $eventArgs)
          $eventArgs.Handled = $true
          if ($script:busy) { return }
          $script:channelIndex = [int]$sender.Tag
          Submit "switch"
        })
        [void]$trailing.Children.Add($switchButton)
      }

      [System.Windows.Controls.Grid]::SetColumn($texts, 0)
      [System.Windows.Controls.Grid]::SetColumn($trailing, 1)
      [void]$grid.Children.Add($texts)
      [void]$grid.Children.Add($trailing)

      # 只有这个图标进编辑页，卡片本身不响应点击，免得抢走「启用」按钮的点击。
      $editButton = New-Object System.Windows.Controls.Button
      $editButton.Style = $window.FindResource("PillIcon")
      # Segoe MDL2 的编辑铅笔字形，和 macOS 侧的 pencil 图标对齐。
      $editButton.Content = [char]0xE70F
      $editButton.FontFamily = "Segoe MDL2 Assets"
      $editButton.FontSize = 14
      $editButton.ToolTip = "编辑渠道"
      $editButton.Tag = $index
      $editButton.Margin = "8,0,0,0"
      $editButton.Add_Click({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        if ($script:busy) { return }
        $script:channelIndex = [int]$sender.Tag
        Show-Detail-Page
      })
      [System.Windows.Controls.Grid]::SetColumn($editButton, 2)
      [void]$grid.Children.Add($editButton)

      $deleteButton = New-Object System.Windows.Controls.Button
      $deleteButton.Style = $window.FindResource("PillIcon")
      # Segoe MDL2 的垃圾桶字形，和 macOS 侧的 trash 图标对齐。
      $deleteButton.Content = [char]0xE74D
      $deleteButton.FontFamily = "Segoe MDL2 Assets"
      $deleteButton.FontSize = 14
      $deleteButton.ToolTip = "删除渠道"
      $deleteButton.Tag = $index
      $deleteButton.Margin = "4,0,0,0"
      $deleteButton.Add_Click({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        Request-Delete "channel" ([int]$sender.Tag)
      })
      [System.Windows.Controls.Grid]::SetColumn($deleteButton, 3)
      [void]$grid.Children.Add($deleteButton)
      $border.Child = $grid
      [void]$channelPanel.Children.Add($border)
    }
    $channelEmpty.Visibility = if ($script:channels.Count -eq 0) { "Visible" } else { "Collapsed" }
  } finally {
    $script:rendering = $false
  }
}

function Show-List-Page {
  $listPage.Visibility = "Visible"
  $detailPage.Visibility = "Collapsed"
  # 回到列表就等于离开编辑页，编辑页的未保存提示不能挂到这里。
  Set-Feedback ""
  Update-ChannelList
  Update-Controls
}

function Show-Detail-Page {
  $listPage.Visibility = "Collapsed"
  $detailPage.Visibility = "Visible"
  Update-ChannelFields
  Rebuild-Rows
  Update-Controls
}

function Update-Controls {
  $hasChannel = $null -ne (Get-ActiveChannel)
  $models = Get-ActiveModels
  $addButton.IsEnabled = $script:loaded -and -not $script:busy -and $hasChannel
  $addChannelButton.IsEnabled = $script:loaded -and -not $script:busy -and $script:channels.Count -lt 50
  $deleteChannelButton.IsEnabled = $script:loaded -and -not $script:busy -and $hasChannel
  $backButton.IsEnabled = -not $script:busy
  foreach ($field in @($channelIdField, $channelBaseUrlField, $channelApiKeyField, $channelHeaderNameField, $channelHeaderValueField)) {
    $field.IsEnabled = $script:loaded -and -not $script:busy -and $hasChannel
  }
  $clearButton.IsEnabled = $script:loaded -and -not $script:busy
  $saveButton.IsEnabled = $script:loaded -and -not $script:busy -and (Compare-Channels $script:channels $script:savedChannels)
  # 没填地址就问不动端点，所以按钮跟着地址一起灰。
  $fetchModelsButton.Content = if ($script:fetchingModels) { "获取中…" } else { "获取可用模型" }
  $fetchModelsButton.IsEnabled = $script:loaded -and -not $script:busy -and $hasChannel -and -not [string]::IsNullOrWhiteSpace([string](Get-ActiveChannel).baseUrl)
  $emptyState.Visibility = if ($script:loaded -and $models.Count -eq 0) { "Visible" } else { "Collapsed" }
}

function Compare-Channels($Left, $Right) {
  if ($Left.Count -ne $Right.Count) { return $true }
  for ($index = 0; $index -lt $Left.Count; $index++) {
    foreach ($field in @("id", "name", "baseUrl", "apiKey", "headerName", "headerValue")) {
      if ([string]$Left[$index].$field -ne [string]$Right[$index].$field) { return $true }
    }
    if (Compare-Models $Left[$index].models $Right[$index].models) { return $true }
  }
  return $false
}

function Compare-Models($Left, $Right) {
  if ($Left.Count -ne $Right.Count) { return $true }
  for ($index = 0; $index -lt $Left.Count; $index++) {
    if ($Left[$index].id -ne $Right[$index].id) { return $true }
    if ([string]$Left[$index].displayName -ne [string]$Right[$index].displayName) { return $true }
    if ($Left[$index].context -ne $Right[$index].context) { return $true }
    $leftModalities = @($Left[$index].inputModalities) -join ","
    $rightModalities = @($Right[$index].inputModalities) -join ","
    if ($leftModalities -ne $rightModalities) { return $true }
  }
  return $false
}

# 渠道是哈希表，直接赋值会共用同一份对象，改动会串到另一份上；这里逐层复制。
function Copy-Channels($Source) {
  return @($Source | ForEach-Object {
    @{
      id = $_.id; name = $_.name; baseUrl = $_.baseUrl; apiKey = $_.apiKey
      headerName = $_.headerName; headerValue = $_.headerValue
      models = @($_.models | ForEach-Object {
        @{
          id = $_.id; displayName = $_.displayName
          context = $_.context; inputModalities = @($_.inputModalities)
        }
      })
    }
  })
}

# 面板进程里 WPF 自带的 Ctrl+V 没有反应，右键也没有默认菜单：直接读 Win32 剪贴板。
function Get-ClipboardText {
  # 别的进程会短暂占住剪贴板，打开失败就重试几次。
  for ($attempt = 0; $attempt -lt 5; $attempt++) {
    if ([GPTSwitch.Native]::OpenClipboard([IntPtr]::Zero)) {
      try {
        $handle = [GPTSwitch.Native]::GetClipboardData(13)
        if ($handle -eq [IntPtr]::Zero) { return $null }
        $pointer = [GPTSwitch.Native]::GlobalLock($handle)
        if ($pointer -eq [IntPtr]::Zero) { return $null }
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($pointer) }
        finally { [void][GPTSwitch.Native]::GlobalUnlock($handle) }
      } finally {
        [void][GPTSwitch.Native]::CloseClipboard()
      }
    }
    Start-Sleep -Milliseconds 30
  }
  return $null
}

function Paste-IntoCell($Box) {
  $text = Get-ClipboardText
  if ([string]::IsNullOrEmpty($text)) {
    Set-Feedback "剪贴板里没有文本" $true
    return
  }
  # 输入框是单行的，换行直接丢掉，避免粘出带换行的模型 ID。
  $plain = $text -replace "\r?\n", ""
  # 密钥框是 PasswordBox，没有 SelectedText。
  if ($Box -is [System.Windows.Controls.PasswordBox]) {
    $Box.Password = $plain
    return
  }
  $Box.SelectedText = $plain
}

function Add-CellClipboard($Box) {
  $copyItem = New-Object System.Windows.Controls.MenuItem
  $copyItem.Header = "复制"
  $copyItem.Add_Click({
    param($sender, $eventArgs)
    $target = $sender.Parent.PlacementTarget
    # 密钥框是 PasswordBox，没有 SelectedText，只能整段取。
    $selected = if ($target -is [System.Windows.Controls.PasswordBox]) { $target.Password } else { $target.SelectedText }
    if ($target -and $selected) {
      try { [System.Windows.Clipboard]::SetText($selected) }
      catch { Set-Feedback "写入剪贴板失败：$($_.Exception.Message)" $true }
    }
  })
  $pasteItem = New-Object System.Windows.Controls.MenuItem
  $pasteItem.Header = "粘贴"
  $pasteItem.Add_Click({
    param($sender, $eventArgs)
    Paste-IntoCell $sender.Parent.PlacementTarget
  })
  $menu = New-Object System.Windows.Controls.ContextMenu
  [void]$menu.Items.Add($copyItem)
  [void]$menu.Items.Add($pasteItem)
  $Box.ContextMenu = $menu

  $Box.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -ne [System.Windows.Input.Key]::V) { return }
    if (-not ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { return }
    $eventArgs.Handled = $true
    Paste-IntoCell $sender
  })
}

# 模型卡片里的一格：标题 + 一行输入控件。
function New-ModelFieldBlock([string]$Title, [System.Windows.FrameworkElement[]]$Fields) {
  $block = New-Object System.Windows.Controls.StackPanel
  $label = New-Object System.Windows.Controls.TextBlock
  $label.Text = $Title
  $label.FontSize = 13
  $label.FontWeight = "Medium"
  $label.Foreground = "#656667"
  [void]$block.Children.Add($label)
  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = "Horizontal"
  $row.Margin = "0,4,0,0"
  foreach ($field in $Fields) { [void]$row.Children.Add($field) }
  [void]$block.Children.Add($row)
  return $block
}

function New-ModelBox([hashtable]$Tag, [string]$Text, [double]$Width) {
  $box = New-Object System.Windows.Controls.TextBox
  $box.Style = $window.FindResource("Field")
  $box.Text = $Text
  $box.Width = $Width
  $box.Tag = $Tag
  $box.IsEnabled = $script:loaded -and -not $script:busy
  $box.Add_TextChanged({ param($sender, $eventArgs) Update-Model $sender $sender.Tag.field })
  Add-CellClipboard $box
  return $box
}

function Rebuild-Rows {
  $models = Get-ActiveModels
  $script:rendering = $true
  $rowsPanel.Children.Clear()
  for ($index = 0; $index -lt $models.Count; $index++) {
    $model = $models[$index]
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $window.FindResource("Card")
    $card.Padding = "16,14,16,16"
    $card.Margin = "0,0,0,8"
    $card.Tag = $index

    $content = New-Object System.Windows.Controls.StackPanel
    $enabled = $script:loaded -and -not $script:busy
    # 删除按钮单独一行靠右，和 cc-switch 的垃圾桶位置一致。
    $trashRow = New-Object System.Windows.Controls.StackPanel
    $trashRow.Orientation = "Horizontal"
    $trashRow.HorizontalAlignment = "Right"
    $trash = New-Object System.Windows.Controls.Button
    $trash.Style = $window.FindResource("PillIcon")
    $trash.Content = [char]0xE74D
    $trash.FontFamily = "Segoe MDL2 Assets"
    $trash.FontSize = 14
    $trash.Width = 24
    $trash.Height = 24
    $trash.ToolTip = "删除模型"
    $trash.Tag = $index
    $trash.IsEnabled = $enabled
    $trash.Add_Click({ param($sender, $eventArgs) Request-Delete "model" ([int]$sender.Tag) })
    [void]$trashRow.Children.Add($trash)
    [void]$content.Children.Add($trashRow)

    $idBox = New-ModelBox @{ index = $index; field = "id" } ([string]$model.id) 300
    $idBox.HorizontalAlignment = "Stretch"
    [void]$content.Children.Add((New-ModelFieldBlock "模型 ID" @($idBox)))

    $contextBox = New-ModelBox @{ index = $index; field = "context" } ([string]$model.context) 148
    $contextBox.Margin = "0,0,0,0"
    $contextBlock = New-ModelFieldBlock "上下文窗口（k）" @($contextBox)
    $sizeText = New-Object System.Windows.Controls.TextBlock
    $sizeText.Text = "约 $(Convert-Context ([int]$model.context))"
    $sizeText.FontSize = 12
    $sizeText.Foreground = "#88898A"
    $sizeText.VerticalAlignment = "Bottom"
    $sizeText.Margin = "10,0,0,5"
    $sizeText.Tag = $index
    $contextRow = New-Object System.Windows.Controls.StackPanel
    $contextRow.Orientation = "Horizontal"
    [void]$contextRow.Children.Add($contextBlock)
    [void]$contextRow.Children.Add($sizeText)
    [void]$content.Children.Add($contextRow)

    $modalityLabel = New-Object System.Windows.Controls.TextBlock
    $modalityLabel.Text = "输入类型"
    $modalityLabel.FontSize = 13
    $modalityLabel.FontWeight = "Medium"
    $modalityLabel.Foreground = "#656667"
    [void]$content.Children.Add($modalityLabel)
    $modalityRow = New-Object System.Windows.Controls.StackPanel
    $modalityRow.Orientation = "Horizontal"
    $modalityRow.Margin = "0,4,0,0"
    foreach ($modality in @("text", "image")) {
      $check = New-Object System.Windows.Controls.CheckBox
      $check.Content = if ($modality -eq "text") { "文本" } else { "图片" }
      $check.FontSize = 14
      $check.IsEnabled = $enabled
      $check.Tag = @{ index = $index; modality = $modality }
      $check.IsChecked = @($model.inputModalities) -contains $modality
      $check.Margin = if ($modality -eq "text") { "0,0,14,0" } else { "0" }
      $check.Add_Click({ param($sender, $eventArgs) Toggle-Modality $sender })
      [void]$modalityRow.Children.Add($check)
    }
    [void]$content.Children.Add($modalityRow)

    $card.Child = $content
    [void]$rowsPanel.Children.Add($card)
  }
  $script:rendering = $false
}

function Update-Model($Sender, [string]$Field) {
  if ($script:rendering -or $script:busy) { return }
  $channel = Get-ActiveChannel
  if (-not $channel) { return }
  $index = [int]$Sender.Tag.index
  if ($index -lt 0 -or $index -ge $channel.models.Count) { return }
  switch ($Field) {
    "id" { $channel.models[$index].id = $Sender.Text }
    "displayName" { $channel.models[$index].displayName = $Sender.Text }
    "context" {
      $value = 0
      if ([int]::TryParse($Sender.Text.Trim(), [ref]$value) -and $value -ge 1) {
        $channel.models[$index].context = $value
        # 卡片最后一行是输入类型，会话大小在倒数第二行。
        $card = $rowsPanel.Children[$index]
        $sizeText = $card.Child.Children[2].Children[1]
        $sizeText.Text = "约 $(Convert-Context $value)"
      }
    }
  }
  Set-Feedback $(if (Compare-Channels $script:channels $script:savedChannels) { "有未保存的更改" } else { "" })
  Update-Controls
}

# 关掉唯一的输入类型会让配置不可用，所以最后一个勾不能取消。
function Toggle-Modality($Sender) {
  if ($script:rendering -or $script:busy) { return }
  $channel = Get-ActiveChannel
  if (-not $channel) { return }
  $index = [int]$Sender.Tag.index
  $modality = [string]$Sender.Tag.modality
  if ($index -lt 0 -or $index -ge $channel.models.Count) { return }
  $current = @($channel.models[$index].inputModalities)
  if ($Sender.IsChecked -eq $true) {
    if ($current -notcontains $modality) { $current += $modality }
  } else {
    $remaining = @($current | Where-Object { $_ -ne $modality })
    if ($remaining.Count -eq 0) {
      $Sender.IsChecked = $true
      return
    }
    $current = $remaining
  }
  $channel.models[$index].inputModalities = $current
  Set-Feedback $(if (Compare-Channels $script:channels $script:savedChannels) { "有未保存的更改" } else { "" })
  Update-Controls
}

# 面板里认这条渠道用的名字：有显示名就「名字 (id)」，否则只给 id。
function Get-ChannelLabel($Channel) {
  $id = ([string]$Channel.id).Trim()
  $name = ([string]$Channel.name).Trim()
  if ([string]::IsNullOrWhiteSpace($id)) {
    if ([string]::IsNullOrWhiteSpace($name)) { return "未命名渠道" }
    return $name
  }
  if ([string]::IsNullOrWhiteSpace($name) -or $name -eq $id) { return $id }
  return "$name ($id)"
}

# 列表页、编辑页和模型卡片的删除都先弹这张卡片，确认后才真正删。
function Request-Delete([string]$Kind, [int]$Index) {
  if ($script:busy) { return }
  if ($Kind -eq "channel") {
    if ($Index -lt 0 -or $Index -ge $script:channels.Count) { return }
    $label = Get-ChannelLabel $script:channels[$Index]
    $confirmTitle.Text = "删除 $label?"
    $confirmMessage.Text = "删除 $label 会移除其配置和存储的 API 密钥。"
    $confirmDelete.Content = "删除 $label"
  } else {
    $channel = Get-ActiveChannel
    if (-not $channel) { return }
    if ($Index -lt 0 -or $Index -ge $channel.models.Count) { return }
    $modelId = [string]$channel.models[$Index].id
    $label = if ([string]::IsNullOrWhiteSpace($modelId)) { "未命名模型" } else { $modelId }
    $confirmTitle.Text = "删除模型「$label」？"
    $confirmMessage.Text = "会从当前渠道的模型目录里移除它，保存后生效。"
    $confirmDelete.Content = "删除"
  }
  $script:deleteKind = $Kind
  $script:deleteIndex = $Index
  $confirmLayer.Visibility = "Visible"
}

function Hide-DeleteConfirm {
  $script:deleteKind = ""
  $script:deleteIndex = -1
  $confirmLayer.Visibility = "Collapsed"
}

# 问渠道端点要它公布的模型；拿回来的清单先在卡片里勾选，不直接进目录。
function Fetch-Models {
  if ($script:busy -or -not $script:loaded) { return }
  $channel = Get-ActiveChannel
  if (-not $channel -or [string]::IsNullOrWhiteSpace([string]$channel.baseUrl)) { return }
  $script:busy = $true
  $script:fetchingModels = $true
  Set-Feedback "正在获取可用模型…"
  Update-Controls
  Send-Request @{
    action = "list-models"
    baseUrl = [string]$channel.baseUrl
    apiKey = [string]$channel.apiKey
    headerName = [string]$channel.headerName
    headerValue = [string]$channel.headerValue
  }
}

# 端点清单先弹卡片勾选，点「添加所选」才进模型目录。
function Show-ModelPicker($Models) {
  $script:discoveredModels = @($Models)
  $script:discoveredSelection = @{}
  $script:rendering = $true
  try {
    $discoverSearch.Text = ""
    $discoverHint.Visibility = "Visible"
  } finally {
    $script:rendering = $false
  }
  $script:discovering = $true
  Update-DiscoveryList
  $discoverLayer.Visibility = "Visible"
  # 打开就把焦点放进搜索框，别让键盘还留在被遮住的表单上。
  $discoverSearch.Focus() | Out-Null
}

function Hide-ModelPicker {
  $script:discovering = $false
  $script:discoveredModels = @()
  $script:discoveredSelection = @{}
  $discoverList.Children.Clear()
  $discoverLayer.Visibility = "Collapsed"
}

# 按搜索框筛出来的行重建勾选列表。
function Update-DiscoveryList {
  $discoverList.Children.Clear()
  $keyword = $discoverSearch.Text.Trim().ToLower()
  foreach ($row in $script:discoveredModels) {
    $id = [string]$row.id
    if ($keyword -and -not $id.ToLower().Contains($keyword)) { continue }
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = $id
    $check.FontFamily = "Consolas"
    $check.FontSize = 14
    $check.Margin = "0,0,0,8"
    $check.Tag = $id
    $check.IsChecked = $script:discoveredSelection.ContainsKey($id)
    $check.Add_Click({ param($sender, $eventArgs) Toggle-Discovered $sender })
    [void]$discoverList.Children.Add($check)
  }
  Refresh-DiscoverySelection
}

# 只刷「全选」和「添加所选」的状态，不重建列表，免得勾一下就丢焦点。
function Refresh-DiscoverySelection {
  $all = $discoverList.Children.Count -gt 0
  foreach ($check in $discoverList.Children) {
    if ($check.IsChecked -ne $true) { $all = $false; break }
  }
  $discoverSelectAll.IsChecked = $all
  $discoverAdd.IsEnabled = $script:discoveredSelection.Count -gt 0
}

function Toggle-Discovered($Sender) {
  $id = [string]$Sender.Tag
  if ($Sender.IsChecked -eq $true) { $script:discoveredSelection[$id] = $true }
  else { [void]$script:discoveredSelection.Remove($id) }
  Refresh-DiscoverySelection
}

# 勾上的补进当前渠道；已经在目录里的不重复加。
function Add-SelectedModels {
  $channel = Get-ActiveChannel
  if (-not $channel) { Hide-ModelPicker; Update-Controls; return }
  $existing = @{}
  foreach ($model in @($channel.models)) { $existing[[string]$model.id] = $true }
  $added = 0
  foreach ($row in $script:discoveredModels) {
    $id = [string]$row.id
    if (-not $script:discoveredSelection.ContainsKey($id) -or $existing.ContainsKey($id)) { continue }
    $channel.models = @($channel.models) + @{
      id = $id
      displayName = [string]$row.displayName
      context = $(if ($null -ne $row.context) { [int]$row.context } else { 272 })
      inputModalities = @("text", "image")
    }
    $existing[$id] = $true
    $added += 1
  }
  Hide-ModelPicker
  Rebuild-Rows
  Set-Feedback $(if ($added -gt 0) { "已添加 $added 个模型，点「保存」后生效" } else { "勾选的模型都已经在目录里" })
  Update-Controls
}

function Remove-Model([int]$Index) {
  if ($script:busy) { return }
  $channel = Get-ActiveChannel
  if (-not $channel) { return }
  if ($Index -lt 0 -or $Index -ge $channel.models.Count) { return }
  $remaining = @()
  for ($position = 0; $position -lt $channel.models.Count; $position++) {
    if ($position -ne $Index) { $remaining += $channel.models[$position] }
  }
  $channel.models = $remaining
  Rebuild-Rows
  Set-Feedback $(if (Compare-Channels $script:channels $script:savedChannels) { "有未保存的更改" } else { "" })
  Update-Controls
}

# 列表页的垃圾桶和编辑页的「删除渠道」共用这一份：删完立刻落盘并回列表页。
function Remove-Channel([int]$Index) {
  if ($script:busy) { return }
  if ($Index -lt 0 -or $Index -ge $script:channels.Count) { return }
  $channel = $script:channels[$Index]
  $script:pendingDeleteRestore = Copy-Channels $script:channels
  $script:pendingDeleteNote = if ([string]::IsNullOrWhiteSpace([string]$channel.id)) { "已删除渠道" } else { "已删除渠道「$($channel.id)」" }
  $remaining = @()
  for ($position = 0; $position -lt $script:channels.Count; $position++) {
    if ($position -ne $Index) { $remaining += $script:channels[$position] }
  }
  $script:channels = $remaining
  $script:channelIndex = if ($script:channels.Count -eq 0) { -1 } else { [Math]::Min($Index, $script:channels.Count - 1) }
  Show-List-Page
  Submit "save" "正在删除渠道…"
}

function Update-ChannelField([string]$Field, [string]$Value) {
  if ($script:rendering -or $script:busy) { return }
  $channel = Get-ActiveChannel
  if (-not $channel) { return }
  $channel[$Field] = $Value
  if ($Field -eq "id") {
    $pageTitle.Text = if ([string]::IsNullOrWhiteSpace($Value)) { "添加渠道" } else { $Value }
  }
  Set-Feedback $(if (Compare-Channels $script:channels $script:savedChannels) { "有未保存的更改" } else { "" })
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
  if ($script:fetchingModels) {
    $script:fetchingModels = $false
    $script:busy = $false
    $channel = Get-ActiveChannel
    if ($Response.ok -eq $true -and $null -ne $Response.models -and $channel) {
      Show-ModelPicker $Response.models
      Set-Feedback "已获取 $(@($Response.models).Count) 个可用模型，勾选后添加"
    } else {
      Set-Feedback $(if ($Response.error) { [string]$Response.error } else { "获取可用模型失败" }) $true
    }
    Update-Controls
    return
  }
  $script:busy = $false
  $ok = $Response.ok -eq $true
  $cleared = $Response.cleared -eq $true
  if ($ok -or $Response.saved -eq $true -or $cleared) {
    if ($null -ne $Response.channels) {
      $previousId = ""
      $active = Get-ActiveChannel
      if ($active) { $previousId = [string]$active.id }
      $script:channels = @($Response.channels | ForEach-Object {
        @{
          id = [string]$_.id
          name = [string]$_.name
          baseUrl = [string]$_.baseUrl
          apiKey = [string]$_.apiKey
          headerName = [string]$_.headerName
          headerValue = [string]$_.headerValue
          models = @($_.models | ForEach-Object {
            @{
              id = [string]$_.id; displayName = [string]$_.displayName
              context = [int]$_.context; inputModalities = @($_.inputModalities)
            }
          })
        }
      })
      $script:savedChannels = Copy-Channels $script:channels
      $script:currentChannelId = [string]$Response.current
      $script:loaded = $true
      $wanted = 0
      if ($previousId) {
        for ($i = 0; $i -lt $script:channels.Count; $i++) {
          if ($script:channels[$i].id -eq $previousId) { $wanted = $i; break }
        }
      }
      $script:channelIndex = if ($script:channels.Count -eq 0) { -1 } else { [Math]::Min($wanted, $script:channels.Count - 1) }
      Update-ChannelFields
      Rebuild-Rows
      if ($cleared -or $Response.restarted -eq $true -or $script:channelIndex -lt 0) {
        Show-List-Page
      } else {
        Update-ChannelList
      }
    }
  }
  if (-not $ok) {
    # 删除没能存盘就把刚拿掉的那条放回去，别让面板和文件对不上。
    if ($script:pendingDeleteRestore) {
      $script:channels = $script:pendingDeleteRestore
      $script:channelIndex = if ($script:channels.Count -eq 0) { -1 } else { [Math]::Min($script:channelIndex, $script:channels.Count - 1) }
      Update-ChannelList
    }
    Set-Feedback $(if ($Response.error) { [string]$Response.error } else { "操作失败" }) $true
  } elseif ($cleared) {
    Set-Feedback "已清空并重启 ChatGPT"
  } elseif ($Response.restarted -eq $true) {
    Set-Feedback "已启用渠道，ChatGPT 已重启"
  } elseif ($Response.saved -eq $true) {
    Set-Feedback $(if ($script:pendingDeleteNote) { $script:pendingDeleteNote } else { "已保存，点列表里的「启用」才会生效" })
  } else {
    Set-Feedback ""
  }
  $script:pendingDeleteRestore = $null
  $script:pendingDeleteNote = ""
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

function Submit([string]$Action, [string]$Note = "") {
  if (-not $script:loaded -or $script:busy) { return }
  $channel = Get-ActiveChannel
  # 保存整份列表不需要当前渠道（删掉最后一个之后也要能存），只有切换渠道才必须有。
  if ($Action -eq "switch" -and -not $channel) { return }
  $script:busy = $true
  Set-Feedback $(if ($Note) { $Note } elseif ($Action -eq "switch") { "正在启用渠道并重启 ChatGPT…" } else { "正在保存…" })
  Rebuild-Rows
  Update-Controls
  Send-Request @{
    action = $Action
    restart = ($Action -eq "switch")
    current = $(if ($Action -eq "switch") { [string]$channel.id } else { [string]$script:currentChannelId })
    channels = @($script:channels | ForEach-Object {
      @{
        id = [string]$_.id; name = [string]$_.name; baseUrl = [string]$_.baseUrl
        apiKey = [string]$_.apiKey; headerName = [string]$_.headerName; headerValue = [string]$_.headerValue
        models = @($_.models | ForEach-Object {
          @{
            id = [string]$_.id; displayName = [string]$_.displayName
            context = [int]$_.context; inputModalities = @($_.inputModalities)
          }
        })
      }
    })
  }
}

$addButton.Add_Click({
  if (-not $script:loaded -or $script:busy) { return }
  $channel = Get-ActiveChannel
  if (-not $channel) { return }
  $channel.models = @($channel.models) + @{
    id = ""; displayName = ""; context = 272; inputModalities = @("text", "image")
  }
  Rebuild-Rows
  Set-Feedback "有未保存的更改"
  Update-Controls
  $newCard = $rowsPanel.Children[$rowsPanel.Children.Count - 1]
  $newCard.Child.Children[1].Children[1].Children[0].Focus() | Out-Null
})

$saveButton.Add_Click({ Submit "save" })

$fetchModelsButton.Add_Click({ Fetch-Models })

$closeDiscovery = {
  Hide-ModelPicker
  Set-Feedback $(if (Compare-Channels $script:channels $script:savedChannels) { "有未保存的更改" } else { "" })
}
$discoverClose.Add_Click($closeDiscovery)
$discoverCancel.Add_Click($closeDiscovery)
$discoverAdd.Add_Click({ Add-SelectedModels })
$discoverSelectAll.Add_Click({
  $on = $discoverSelectAll.IsChecked -eq $true
  foreach ($check in $discoverList.Children) {
    $check.IsChecked = $on
    $id = [string]$check.Tag
    if ($on) { $script:discoveredSelection[$id] = $true }
    else { [void]$script:discoveredSelection.Remove($id) }
  }
  Refresh-DiscoverySelection
})
$discoverSearch.Add_TextChanged({
  $discoverHint.Visibility = if ([string]::IsNullOrEmpty($discoverSearch.Text)) { "Visible" } else { "Collapsed" }
  if ($script:discovering) { Update-DiscoveryList }
})

$addChannelButton.Add_Click({
  if (-not $script:loaded -or $script:busy -or $script:channels.Count -ge 50) { return }
  $script:channels = @($script:channels) + @{
    id = ""; name = ""; baseUrl = ""; apiKey = ""
    headerName = ""; headerValue = ""; models = @()
  }
  $script:channelIndex = $script:channels.Count - 1
  Show-Detail-Page
  Set-Feedback "有未保存的更改"
  $channelIdField.Focus() | Out-Null
})

# 返回列表＝丢弃编辑页里没保存的改动，不弹确认框。
$backButton.Add_Click({
  if ($script:busy) { return }
  $script:channels = Copy-Channels $script:savedChannels
  Show-List-Page
})

$deleteChannelButton.Add_Click({
  if ($script:busy) { return }
  Request-Delete "channel" $script:channelIndex
})

$confirmClose.Add_Click({ Hide-DeleteConfirm })
$confirmCancel.Add_Click({ Hide-DeleteConfirm })
$confirmDelete.Add_Click({
  $kind = $script:deleteKind
  $index = $script:deleteIndex
  Hide-DeleteConfirm
  if ($kind -eq "channel") { Remove-Channel $index }
  elseif ($kind -eq "model") { Remove-Model $index }
})

$channelIdField.Add_TextChanged({ Update-ChannelField "id" $channelIdField.Text })
$channelBaseUrlField.Add_TextChanged({ Update-ChannelField "baseUrl" $channelBaseUrlField.Text })
# 密钥框是 PasswordBox，事件和取值都跟别的输入框不一样。
$channelApiKeyField.Add_PasswordChanged({ Update-ChannelField "apiKey" $channelApiKeyField.Password })
$channelHeaderNameField.Add_TextChanged({ Update-ChannelField "headerName" $channelHeaderNameField.Text })
$channelHeaderValueField.Add_TextChanged({ Update-ChannelField "headerValue" $channelHeaderValueField.Text })

$clearButton.Add_Click({
  if (-not $script:loaded -or $script:busy) { return }
  $answer = [System.Windows.MessageBox]::Show(
    $window,
    "会还原插件写进 ChatGPT 的渠道配置、清掉模型目录并重启客户端；面板里保存的渠道列表保留。",
    "还原 ChatGPT 配置并重启客户端？",
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
Show-List-Page
Rebuild-Rows
Send-Request @{ action = "load" }
# 启动期用 Stop 尽早暴露问题；跑起来之后用 Continue，避免偶发异常把面板整个关掉。
$ErrorActionPreference = "Continue"
[void]$application.Run($window)
$tray.Visible = $false
$tray.Dispose()

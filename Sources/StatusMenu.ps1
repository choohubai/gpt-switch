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
$script:editingCurrent = $false
$script:modelEditorActive = $false
$script:discoveredModels = @()
$script:discoveredSelection = @{}
$script:discovering = $false
$script:modelSizeTexts = @()
$script:proxyHost = "127.0.0.1"
$script:proxyPort = "47123"
$script:savedProxyHost = "127.0.0.1"
$script:savedProxyPort = "47123"
$script:savingProxy = $false
$script:agentsContent = ""
$script:savedAgentsContent = ""
$script:agentsBackupPath = ""
$script:agentsSource = ""
$script:agentsError = ""
$script:agentsEnabled = $false
$script:savedAgentsEnabled = $false
$script:savingAgents = $false
$script:appearanceTheme = "light"
$script:appearanceFollowNative = $false
$script:appearanceNativeMode = "light"
$script:appearanceThemes = @()
$script:savingAppearance = $false
$script:appearanceThemeBeforeSave = "light"
$script:appearanceFollowNativeBeforeSave = $false
$script:appearanceNativeModeBeforeSave = "light"

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
        Title="GPT Switch" Height="700" Width="940" MinHeight="560" MinWidth="820"
        Background="#F7FAF5" FontFamily="Segoe UI" FontSize="13"
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
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
      <Setter Property="Background" Value="#477C51"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#477C51"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="HeaderDivider" TargetType="Border">
      <Setter Property="Height" Value="1"/>
      <Setter Property="Background" Value="#E5E9E3"/>
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
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#656667"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="4,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
                    BorderBrush="#D8E1D5" BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="frame" Property="BorderBrush" Value="#6A956F"/>
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
                    BorderBrush="#D8E1D5" BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="frame" Property="BorderBrush" Value="#6A956F"/>
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
      <Setter Property="Background" Value="#FDFEFC"/>
      <Setter Property="BorderBrush" Value="#DDE5DA"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
    </Style>
    <Style x:Key="Nav" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#3E4740"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="fill" Background="{TemplateBinding Background}" CornerRadius="8">
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavActive" TargetType="Button" BasedOn="{StaticResource Nav}">
      <Setter Property="Background" Value="#21336B40"/>
      <Setter Property="Foreground" Value="#336B40"/>
    </Style>
    <Style x:Key="NavGlyph" TargetType="Path">
      <Setter Property="Width" Value="14"/>
      <Setter Property="Height" Value="14"/>
      <Setter Property="Margin" Value="2,0,10,0"/>
      <Setter Property="Stretch" Value="Uniform"/>
      <Setter Property="Fill" Value="Transparent"/>
      <Setter Property="Stroke" Value="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
      <Setter Property="StrokeThickness" Value="1.5"/>
      <Setter Property="StrokeStartLineCap" Value="Round"/>
      <Setter Property="StrokeEndLineCap" Value="Round"/>
      <Setter Property="StrokeLineJoin" Value="Round"/>
    </Style>
    <Style x:Key="ThemeCard" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <ContentPresenter/>
              <Border x:Name="focus" BorderBrush="Transparent" BorderThickness="1"
                      CornerRadius="11" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Opacity" Value="0.94"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="focus" Property="BorderBrush" Value="#336B40"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ChannelSwitch" TargetType="ToggleButton">
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="20"/>
      <Setter Property="Background" Value="#CFD7CE"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="track" Background="{TemplateBinding Background}" CornerRadius="10">
              <Grid>
                <Ellipse x:Name="thumb" Width="14" Height="14" Margin="3"
                         HorizontalAlignment="Left" Fill="#FFFFFF">
                  <Ellipse.Effect>
                    <DropShadowEffect BlurRadius="2" ShadowDepth="1" Direction="270" Opacity="0.25"/>
                  </Ellipse.Effect>
                </Ellipse>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#4C8156"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="track" Property="Opacity" Value="0.86"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="track" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="190"/>
      <ColumnDefinition Width="1"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border x:Name="Sidebar" Grid.RowSpan="2" Grid.Column="0" Background="#EDF4EA">
      <StackPanel Margin="8,22,8,16">
        <TextBlock Text="GPT Switch" FontSize="16" FontWeight="SemiBold" Foreground="#202522"
                   Margin="14,0,0,18"/>
        <TextBlock Text="设置" FontSize="11" FontWeight="Medium" Foreground="#747D76"
                   Margin="14,0,0,8"/>
        <Button x:Name="ModelsTab" Style="{StaticResource NavActive}">
          <StackPanel Orientation="Horizontal">
            <Path Style="{StaticResource NavGlyph}" Data="M12,2 L21,7 21,17 12,22 3,17 3,7 Z M3,7 12,12 21,7 M12,12 12,22"/>
            <TextBlock Text="模型"/>
          </StackPanel>
        </Button>
        <Button x:Name="ProxyTab" Style="{StaticResource Nav}">
          <StackPanel Orientation="Horizontal">
            <Path Style="{StaticResource NavGlyph}" Data="M9,2 L15,2 15,8 9,8 Z M2,16 L8,16 8,22 2,22 Z M16,16 L22,16 22,22 16,22 Z M5,16 5,13 19,13 19,16 M12,13 12,8"/>
            <TextBlock Text="代理"/>
          </StackPanel>
        </Button>
        <Button x:Name="GeneralTab" Style="{StaticResource Nav}">
          <StackPanel Orientation="Horizontal">
            <Path Style="{StaticResource NavGlyph}" Data="M9.5,2 L14.5,2 15.3,4.4 17.2,5.2 19.5,4.2 22,7.8 20.1,9.5 20.1,11.5 22,13.2 19.5,16.8 17.2,15.8 15.3,16.6 14.5,19 9.5,19 8.7,16.6 6.8,15.8 4.5,16.8 2,13.2 3.9,11.5 3.9,9.5 2,7.8 4.5,4.2 6.8,5.2 8.7,4.4 Z M15,10.5 A3,3 0 1 1 9,10.5 A3,3 0 1 1 15,10.5"/>
            <TextBlock Text="通用"/>
          </StackPanel>
        </Button>
        <Button x:Name="AppearanceTab" Style="{StaticResource Nav}">
          <StackPanel Orientation="Horizontal">
            <Path Style="{StaticResource NavGlyph}"
                  Data="M12,21 A9,9 0 0 1 12,3 C16.97,3 21,6.582 21,11 C21,13.06 19.025,15 16.5,15 L14,15 A2,2 0 0 0 13,18.75 A1.3,1.3 0 0 1 12,21 M7.5,10.5 A1,1 0 1 0 9.5,10.5 A1,1 0 1 0 7.5,10.5 M11.5,7.5 A1,1 0 1 0 13.5,7.5 A1,1 0 1 0 11.5,7.5 M15.5,10.5 A1,1 0 1 0 17.5,10.5 A1,1 0 1 0 15.5,10.5"/>
            <TextBlock Text="外观"/>
          </StackPanel>
        </Button>
        <Button x:Name="AgentsTab" Style="{StaticResource Nav}">
          <StackPanel Orientation="Horizontal">
            <Path Style="{StaticResource NavGlyph}" Data="M5,5 A3,3 0 1 1 5,11 A3,3 0 1 1 5,5 M16,4 A3,3 0 1 1 16,10 A3,3 0 1 1 16,4 M2,20 L2,18 C2,15 4,13 7,13 10,13 14,15 14,18 L14,20 M16,13 C19.5,13 22,14.5 22,18 L22,20"/>
            <TextBlock Text="Agents"/>
          </StackPanel>
        </Button>
        <Border Height="1" Background="#DCE5D8" Margin="4,10,4,10"/>
        <Button x:Name="AboutTab" Style="{StaticResource Nav}">
          <StackPanel Orientation="Horizontal">
            <Path Style="{StaticResource NavGlyph}" Data="M12,2 A10,10 0 1 1 12,22 A10,10 0 1 1 12,2 M12,10 L12,16 M12,7 12,7.01"/>
            <TextBlock Text="关于"/>
          </StackPanel>
        </Button>
        <Button x:Name="HelpTab" Style="{StaticResource Nav}">
          <StackPanel Orientation="Horizontal">
            <Path Style="{StaticResource NavGlyph}" Data="M12,2 A10,10 0 1 1 12,22 A10,10 0 1 1 12,2 M9.1,9 A3,3 0 1 1 12,14 L12,15 M12,18 12,18.01"/>
            <TextBlock Text="获取帮助"/>
          </StackPanel>
        </Button>
      </StackPanel>
    </Border>
    <Border Grid.RowSpan="2" Grid.Column="1" Background="#D8E2D4"/>

    <Grid x:Name="ListPage" Grid.Row="0" Grid.Column="2" Margin="28,20,28,20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Grid x:Name="ModelsPage" Grid.Row="0" Margin="0,0,0,14">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="模型" FontSize="20" FontWeight="Normal" Foreground="#202522"/>
          <TextBlock Text="聚合多条渠道，模型合进同一份选择器目录按渠道折叠成组。"
                     FontSize="12" Foreground="#69716A" Margin="0,4,0,0"/>
        </StackPanel>
        <!-- 「重启生效」原来是当前渠道那行上的按钮；它是全局动作，挪到这里只留一个入口。 -->
        <Button x:Name="RestartButton" Grid.Column="1" Style="{StaticResource PillPrimary}" Content="重启 ChatGPT"
                VerticalAlignment="Top"/>
      </Grid>
      <Border x:Name="ModelsCard" Grid.Row="1" Margin="0,16,0,0"
              Background="Transparent" BorderThickness="0">
        <Grid>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <StackPanel x:Name="ChannelPanel"/>
              <Button x:Name="AddChannelButton" Style="{StaticResource Dashed}" Content="＋ 添加渠道"
                      Margin="0,0,0,0"/>
            </StackPanel>
          </ScrollViewer>
          <StackPanel x:Name="ChannelEmpty" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed">
            <TextBlock Text="还没有渠道" FontSize="14" Foreground="#202522" HorizontalAlignment="Center"/>
            <TextBlock Text="点下面的“添加渠道”填地址、密钥和模型" FontSize="12" Foreground="#7B827C"
                       HorizontalAlignment="Center" Margin="0,6,0,0"/>
          </StackPanel>
        </Grid>
      </Border>
      <Grid x:Name="ProxyPage" Grid.RowSpan="2" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid Margin="0,0,0,14">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="代理" FontSize="20" FontWeight="Normal" Foreground="#212327"/>
            <TextBlock Text="控制本地转发服务监听的 IP 和端口；保存后点「重启 ChatGPT」生效。"
                       FontSize="12" Foreground="#69716A" Margin="0,4,0,0"/>
          </StackPanel>
          <Button x:Name="ProxyRestartButton" Grid.Column="1" Style="{StaticResource PillPrimary}"
                  Content="重启 ChatGPT" VerticalAlignment="Top"/>
        </Grid>
        <Border Grid.Row="1" Style="{StaticResource Card}" VerticalAlignment="Top" Margin="0,16,0,0" Padding="18">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Grid.Column="0">
              <TextBlock Text="监听 IP" FontSize="13" FontWeight="Medium" Foreground="#656667"/>
              <TextBox x:Name="ProxyHostField" Style="{StaticResource Field}" Margin="0,4,0,0"/>
              <TextBlock Text="必须是合法 IPv4。建议使用 127.0.0.1；开放到局域网会增加密钥暴露风险。"
                         FontSize="11" Foreground="#88898A" TextWrapping="Wrap" Margin="0,4,0,0"/>
            </StackPanel>
            <StackPanel Grid.Row="0" Grid.Column="2">
              <TextBlock Text="监听端口" FontSize="13" FontWeight="Medium" Foreground="#656667"/>
              <TextBox x:Name="ProxyPortField" Style="{StaticResource Field}" Margin="0,4,0,0"/>
              <TextBlock Text="1024–65535；被占用时自动顺延并更新此端口。"
                         FontSize="11" Foreground="#88898A" TextWrapping="Wrap" Margin="0,4,0,0"/>
            </StackPanel>
            <StackPanel Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="3" Margin="0,24,0,0">
              <TextBlock Text="保存只会写入配置。地址或端口变化后，需要重启 ChatGPT 才能切换服务。"
                         FontSize="11" Foreground="#88898A"/>
              <Button x:Name="SaveProxyButton" Style="{StaticResource Pill}" Content="保存"
                      HorizontalAlignment="Right" Width="76" Margin="0,14,0,0"/>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>
      <Border x:Name="ModelsHeaderDivider" Grid.Row="0" Height="1" Background="#E5E9E3"
              VerticalAlignment="Bottom"/>
    </Grid>

    <Grid x:Name="DetailPage" Grid.Row="0" Grid.Column="2" Margin="28,22,28,20" Visibility="Collapsed">
      <Grid.RowDefinitions>
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
        <Button x:Name="BackButton" Grid.Column="0" Style="{StaticResource Link}"
                Padding="2,0,8,0" VerticalAlignment="Center"
                AutomationProperties.Name="返回">
          <StackPanel Orientation="Horizontal">
            <Path Style="{StaticResource NavGlyph}" Width="16" Height="16"
                  Data="M15,4 7,12 15,20" Margin="0,0,5,0"/>
            <TextBlock Text="返回" Foreground="#656667" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
        <TextBlock x:Name="PageTitle" Grid.Column="1" Text="添加渠道" FontSize="17" FontWeight="SemiBold"
                   Foreground="#202522" VerticalAlignment="Center" Margin="8,0,0,0"/>
        <Button x:Name="DeleteChannelButton" Grid.Column="3" Style="{StaticResource PillDanger}" Content="删除渠道"/>
      </Grid>
      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="0,0,12,12">
          <TextBlock Text="渠道信息" FontSize="12" FontWeight="SemiBold" Foreground="#69716A" Margin="2,0,0,8"/>
          <Border Style="{StaticResource Card}" Padding="22">
            <StackPanel>
              <TextBlock Text="渠道 ID" FontSize="13" FontWeight="Medium" Foreground="#656667"/>
              <TextBox x:Name="ChannelIdField" Style="{StaticResource Field}" Margin="0,4,0,14"/>
              <TextBlock x:Name="ChannelIdHint" FontSize="12" Foreground="#D93025"
                         Margin="0,-10,0,10" TextWrapping="Wrap" Visibility="Collapsed"/>
              <TextBlock Text="API 密钥" FontSize="13" FontWeight="Medium" Foreground="#656667"/>
              <PasswordBox x:Name="ChannelApiKeyField" Style="{StaticResource SecretField}" Margin="0,4,0,14"/>
              <TextBlock Text="API 地址" FontSize="13" FontWeight="Medium" Foreground="#656667"/>
              <TextBox x:Name="ChannelBaseUrlField" Style="{StaticResource Field}" Margin="0,4,0,14"/>
              <TextBlock Text="请求头名（可选）" FontSize="13" FontWeight="Medium" Foreground="#656667"/>
              <TextBox x:Name="ChannelHeaderNameField" Style="{StaticResource Field}" Margin="0,4,0,14"/>
              <TextBlock Text="请求头值" FontSize="13" FontWeight="Medium" Foreground="#656667"/>
              <TextBox x:Name="ChannelHeaderValueField" Style="{StaticResource Field}" Margin="0,4,0,0"/>
              <TextBlock Text="需要自定义请求头的中转才填，留空则不加" FontSize="11" Foreground="#88898A" Margin="0,5,0,0"/>
            </StackPanel>
          </Border>
          <Grid Margin="2,18,2,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="模型目录" FontSize="12" FontWeight="SemiBold" Foreground="#69716A"
                       VerticalAlignment="Center"/>
            <Button x:Name="FetchModelsButton" Grid.Column="1" Style="{StaticResource Link}" Content="获取可用模型"
                    VerticalAlignment="Center"/>
          </Grid>
          <StackPanel x:Name="RowsPanel"/>
          <StackPanel x:Name="EmptyState" HorizontalAlignment="Center" Margin="0,24" Visibility="Collapsed">
            <TextBlock Text="暂无自定义模型" FontSize="14" Foreground="#202522" HorizontalAlignment="Center"/>
            <TextBlock Text="点上方「获取可用模型」后勾选要导入的模型" FontSize="12" Foreground="#88898A"
                       HorizontalAlignment="Center" Margin="0,6,0,0"/>
          </StackPanel>
        </StackPanel>
      </ScrollViewer>
      <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
        <Button x:Name="SaveButton" Style="{StaticResource PillPrimary}" Content="保存"/>
      </StackPanel>
    </Grid>

    <Grid x:Name="SimplePage" Grid.Row="0" Grid.Column="2" Margin="28,20,28,20" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="SimplePageTitle" FontSize="20" FontWeight="Normal" Foreground="#202522"
                 Margin="0,0,0,14"/>
      <Border x:Name="SimpleHeaderDivider" Grid.Row="0" Height="1" Background="#E5E9E3"
              VerticalAlignment="Bottom"/>
    </Grid>

    <Grid x:Name="AgentsPage" Grid.Row="0" Grid.Column="2" Margin="28,20,28,20" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Grid Margin="0,0,0,14">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="Agents" FontSize="20" FontWeight="Normal" Foreground="#202522"/>
          <TextBlock Text="维护所有项目共用的 Markdown 指令。"
                     FontSize="12" Foreground="#69716A" Margin="0,4,0,0"/>
        </StackPanel>
        <Grid Grid.Column="1">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Top" Margin="0,0,18,0">
            <TextBlock Text="启用" FontSize="13" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ToggleButton x:Name="AgentsEnabledToggle" Style="{StaticResource ChannelSwitch}"/>
          </StackPanel>
          <Button x:Name="AgentsRestartButton" Grid.Column="1" Style="{StaticResource PillPrimary}"
                  Content="重启 ChatGPT" VerticalAlignment="Top"/>
        </Grid>
      </Grid>
      <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="18">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="公共指令" FontSize="13" FontWeight="Medium" VerticalAlignment="Center"/>
            <TextBlock Grid.Column="1" Text="~/.codex/AGENTS.md" FontFamily="Consolas"
                       FontSize="11" Foreground="#747D76" VerticalAlignment="Center"/>
          </Grid>
          <TextBox x:Name="AgentsContentField" Grid.Row="1" Style="{StaticResource Field}"
                   AcceptsReturn="True" AcceptsTab="True" TextWrapping="NoWrap"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                   FontFamily="Consolas" FontSize="13" MinHeight="300" Margin="0,10,0,0"/>
          <Grid Grid.Row="2" Margin="0,12,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Text="启用时先备份原 AGENTS.md；关闭只停止同步，不恢复原文件。"
                         FontSize="11" Foreground="#747D76" TextWrapping="Wrap"/>
              <TextBlock x:Name="AgentsBackupLabel" FontSize="11" Foreground="#747D76"
                         FontFamily="Consolas" TextTrimming="CharacterEllipsis" Margin="0,3,0,0"/>
              <TextBlock x:Name="AgentsErrorLabel" FontSize="11" Foreground="#D93025"
                         TextWrapping="Wrap" Margin="0,3,0,0"/>
            </StackPanel>
            <Button x:Name="SaveAgentsButton" Grid.Column="1" Style="{StaticResource PillPrimary}"
                    Content="保存" Width="76" Margin="12,0,0,0"/>
          </Grid>
        </Grid>
      </Border>
      <Border Grid.Row="0" Height="1" Background="#E5E9E3" VerticalAlignment="Bottom"/>
    </Grid>

    <Grid x:Name="AppearancePage" Grid.Row="0" Grid.Column="2" Margin="28,20,28,20" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Grid Margin="0,0,0,14">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="外观" FontSize="20" FontWeight="Normal" Foreground="#202522"/>
          <TextBlock Text="选择后立即改变 ChatGPT 的背景、侧栏、输入框和弹窗。"
                     FontSize="12" Foreground="#69716A" Margin="0,4,0,0"/>
        </StackPanel>
        <Button x:Name="AppearanceRestartButton" Grid.Column="1" Style="{StaticResource PillPrimary}"
                Content="重启 ChatGPT" VerticalAlignment="Top"/>
      </Grid>
      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"
                    PanningMode="VerticalOnly" Margin="0,16,0,0">
        <ScrollViewer.Resources>
          <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="8"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="ScrollBar">
                  <Grid Background="Transparent">
                    <Track x:Name="PART_Track" IsDirectionReversed="True"
                           Orientation="{TemplateBinding Orientation}">
                      <Track.Thumb>
                        <Thumb MinHeight="36">
                          <Thumb.Template>
                            <ControlTemplate TargetType="Thumb">
                              <Border Background="#336B40" CornerRadius="2"
                                      Margin="2,0" Opacity="0.28"/>
                            </ControlTemplate>
                          </Thumb.Template>
                        </Thumb>
                      </Track.Thumb>
                    </Track>
                  </Grid>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </ScrollViewer.Resources>
        <StackPanel Margin="0,0,0,20">
          <Border x:Name="AppearancePreviewFrame" Height="210" MinHeight="160" MaxWidth="560"
                  HorizontalAlignment="Stretch" CornerRadius="12"
                  Background="#E9F2E7" ClipToBounds="True" BorderBrush="#DCE5DA" BorderThickness="1">
            <Grid>
              <Image x:Name="AppearancePreviewImage" Stretch="UniformToFill"/>
              <Border x:Name="AppearancePreviewEmpty" Background="#F2F7F0" CornerRadius="12">
                <TextBlock x:Name="AppearancePreviewEmptyText" Text="正在读取主题…"
                           FontSize="13" Foreground="#6E786F"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Border x:Name="AppearanceBusyOverlay" Background="#33000000" Visibility="Collapsed">
                <TextBlock Text="正在应用…" Foreground="White" FontSize="13" FontWeight="SemiBold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
          </Border>
          <StackPanel Orientation="Horizontal" Margin="0,18,0,12">
            <TextBlock Text="全部主题" FontSize="14" FontWeight="SemiBold" Foreground="#202522"
                       VerticalAlignment="Bottom"/>
            <TextBlock Text="选择后立即应用" FontSize="12" Foreground="#747D76"
                       VerticalAlignment="Bottom" Margin="8,0,0,1"/>
          </StackPanel>
          <WrapPanel x:Name="AppearanceThemePanel"/>
        </StackPanel>
      </ScrollViewer>
      <Border Grid.Row="0" Height="1" Background="#E5E9E3" VerticalAlignment="Bottom"/>
    </Grid>

    <Grid x:Name="AboutPage" Grid.Row="0" Grid.Column="2" Margin="28,20,28,20" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <TextBlock Text="关于" FontSize="20" FontWeight="Normal" Foreground="#202522"
                 Margin="0,0,0,14"/>
      <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="18,0">
        <StackPanel>
          <Grid Height="58">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="当前版本" FontSize="13" FontWeight="Medium" VerticalAlignment="Center"/>
            <TextBlock x:Name="VersionLabel" Grid.Column="1" FontSize="11" Foreground="#747D76"
                       VerticalAlignment="Center" Margin="8,0,0,0"/>
            <Button x:Name="UpdateButton" Grid.Column="2" Style="{StaticResource Link}" Content="检查更新"
                    VerticalAlignment="Center"/>
          </Grid>
          <Border Height="1" Background="#E2E8DF"/>
          <Grid Height="66">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="还原配置" FontSize="13" FontWeight="Medium"/>
              <TextBlock Text="还原 ChatGPT 侧配置与模型目录，面板里的渠道列表保留。"
                         FontSize="11" Foreground="#747D76" Margin="0,3,0,0"/>
            </StackPanel>
            <Button x:Name="ClearButton" Grid.Column="1" Style="{StaticResource Link}" Content="还原配置"
                    VerticalAlignment="Center"/>
          </Grid>
        </StackPanel>
      </Border>
      <Border Grid.Row="0" Height="1" Background="#E5E9E3" VerticalAlignment="Bottom"/>
    </Grid>

    <Border Grid.Row="1" Grid.Column="2" Height="36" Background="#F7FAF5"
            BorderBrush="#DCE4D9" BorderThickness="0,1,0,0">
      <TextBlock x:Name="Feedback" FontSize="11" Foreground="#747D76"
                 TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="28,0"/>
    </Border>

    <!-- 删除统一先走这张卡片：确认后才真正删。 -->
    <Grid x:Name="ConfirmLayer" Grid.Row="0" Grid.RowSpan="2" Grid.ColumnSpan="3"
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
    <!-- 端点清单先在这里勾选，点「导入所选」才进模型目录。 -->
    <Grid x:Name="DiscoverLayer" Grid.Row="0" Grid.RowSpan="2" Grid.ColumnSpan="3"
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
            <TextBlock Grid.Column="0" Text="选择要导入的模型" FontSize="17" FontWeight="SemiBold"
                       Foreground="#212327" VerticalAlignment="Center"/>
            <Button x:Name="DiscoverClose" Grid.Column="1" Style="{StaticResource Link}" Content="✕" FontSize="13"
                    VerticalAlignment="Top" Margin="8,0,0,0"/>
          </Grid>
          <TextBlock Text="以下是模型提供商的可用模型；已有模型会刷新端点明确返回的能力。" FontSize="13" Foreground="#656667"
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
            <Button x:Name="DiscoverAdd" Style="{StaticResource Pill}" Content="导入所选" Height="38" Padding="22,0"
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

$clearButton = $window.FindName("ClearButton")
$restartButton = $window.FindName("RestartButton")
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
$channelIdHint = $window.FindName("ChannelIdHint")
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
$modelsTab = $window.FindName("ModelsTab")
$proxyTab = $window.FindName("ProxyTab")
$generalTab = $window.FindName("GeneralTab")
$appearanceTab = $window.FindName("AppearanceTab")
$agentsTab = $window.FindName("AgentsTab")
$aboutTab = $window.FindName("AboutTab")
$helpTab = $window.FindName("HelpTab")
$modelsPage = $window.FindName("ModelsPage")
$modelsCard = $window.FindName("ModelsCard")
$proxyPage = $window.FindName("ProxyPage")
$simplePage = $window.FindName("SimplePage")
$simplePageTitle = $window.FindName("SimplePageTitle")
$agentsPage = $window.FindName("AgentsPage")
$appearancePage = $window.FindName("AppearancePage")
$appearancePreviewFrame = $window.FindName("AppearancePreviewFrame")
$appearancePreviewImage = $window.FindName("AppearancePreviewImage")
$appearancePreviewEmpty = $window.FindName("AppearancePreviewEmpty")
$appearancePreviewEmptyText = $window.FindName("AppearancePreviewEmptyText")
$appearanceBusyOverlay = $window.FindName("AppearanceBusyOverlay")
$appearanceThemePanel = $window.FindName("AppearanceThemePanel")
$appearanceRestartButton = $window.FindName("AppearanceRestartButton")
$agentsEnabledToggle = $window.FindName("AgentsEnabledToggle")
$agentsRestartButton = $agentsPage.FindName("AgentsRestartButton")
$agentsContentField = $window.FindName("AgentsContentField")
$agentsBackupLabel = $window.FindName("AgentsBackupLabel")
$agentsErrorLabel = $window.FindName("AgentsErrorLabel")
$saveAgentsButton = $window.FindName("SaveAgentsButton")
$aboutPage = $window.FindName("AboutPage")
$proxyHostField = $window.FindName("ProxyHostField")
$proxyPortField = $window.FindName("ProxyPortField")
$saveProxyButton = $window.FindName("SaveProxyButton")
$proxyRestartButton = $proxyPage.FindName("ProxyRestartButton")
$clearButton = $window.FindName("ClearButton")
$restartButton = $window.FindName("RestartButton")

# 面板由原生 GPT Switch.exe 承载，仍显式设置图标以覆盖宿主默认图标。
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
  Update-ChannelIdHint
}

function Update-ChannelList {
  $script:rendering = $true
  try {
    $channelPanel.Children.Clear()
    for ($index = 0; $index -lt $script:channels.Count; $index++) {
      $channel = $script:channels[$index]
      if ($null -eq $channel -or [string]::IsNullOrWhiteSpace([string]$channel.id)) { continue }
      $border = New-Object System.Windows.Controls.Border
      $border.BorderThickness = "1"
      $border.BorderBrush = "#DDE5DA"
      $border.Background = "#FBFCFA"
      $border.CornerRadius = "14"
      $border.Padding = "16,0"
      $border.Margin = "0,0,0,10"
      $border.Height = 64
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
      $idText.Foreground = "#202522"
      $idText.TextTrimming = "CharacterEllipsis"
      $urlText = New-Object System.Windows.Controls.TextBlock
      $urlText.Text = if ([string]::IsNullOrWhiteSpace([string]$channel.baseUrl)) { "还没填地址" } else { [string]$channel.baseUrl }
      $urlText.FontSize = 12
      $urlText.Foreground = "#69716A"
      $urlText.TextTrimming = "CharacterEllipsis"
      [void]$texts.Children.Add($idText)
      [void]$texts.Children.Add($urlText)

      # 每条渠道一个开关：禁用只影响这一条，别的渠道照常用。
      $trailing = New-Object System.Windows.Controls.StackPanel
      $trailing.Orientation = "Horizontal"
      $trailing.VerticalAlignment = "Center"
      $isEnabled = $channel.enabled -ne $false
      $statusBadge = New-Object System.Windows.Controls.Border
      $statusBadge.CornerRadius = "6"
      $statusBadge.Padding = "8,3"
      $statusBadge.Background = if ($isEnabled) { "#E4EFE2" } else { "#EEF1ED" }
      $statusText = New-Object System.Windows.Controls.TextBlock
      $statusText.Text = if ($isEnabled) { "已启用" } else { "已禁用" }
      $statusText.FontSize = 10.5
      $statusText.FontWeight = "SemiBold"
      $statusText.Foreground = if ($isEnabled) { "#3F7149" } else { "#737B74" }
      $statusText.VerticalAlignment = "Center"
      $statusBadge.Child = $statusText
      [void]$trailing.Children.Add($statusBadge)
      $toggleButton = New-Object System.Windows.Controls.Primitives.ToggleButton
      $toggleButton.Style = $window.FindResource("ChannelSwitch")
      $toggleButton.IsChecked = $isEnabled
      $toggleButton.Tag = $index
      $toggleButton.Margin = "10,0,0,0"
      $toggleButton.ToolTip = if ($isEnabled) { "禁用这条渠道" } else { "启用这条渠道" }
      $toggleButton.Add_Click({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        if ($script:busy) { return }
        $target = [int]$sender.Tag
        if ($target -lt 0 -or $target -ge $script:channels.Count) { return }
        # 单条渠道的启用/禁用：只翻这一条的开关并落盘，不碰别的渠道，也不重启客户端。
        # 整份渠道列表一起校验，别的渠道有问题时这一条也会被拒：先留一份原文，存盘失败退回原样。
        $script:pendingDeleteRestore = Copy-Channels $script:channels
        $script:channels[$target].enabled = $script:channels[$target].enabled -eq $false
        if ($script:channels[$target].enabled) {
          $script:pendingDeleteNote = "已启用渠道「$([string]$script:channels[$target].id)」"
          Submit "save" "正在启用渠道…"
        } else {
          $script:pendingDeleteNote = "已禁用渠道「$([string]$script:channels[$target].id)」"
          Submit "save" "正在禁用渠道…"
        }
      })
      [void]$trailing.Children.Add($toggleButton)

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
      $editButton.Margin = "6,0,0,0"
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
      $deleteButton.Margin = "2,0,0,0"
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

function Set-Nav([string]$Active) {
  $targets = @{
    models = $modelsTab
    proxy = $proxyTab
    general = $generalTab
    appearance = $appearanceTab
    agents = $agentsTab
    about = $aboutTab
    help = $helpTab
  }
  foreach ($name in $targets.Keys) {
    $targets[$name].Style = $window.FindResource($(if ($name -eq $Active) { "NavActive" } else { "Nav" }))
  }
}

function Show-Models-Page {
  if ($script:modelEditorActive) { Show-Detail-Page } else { Show-List-Page }
}

function Show-List-Page {
  $discardedDraft = $false
  if (-not (Test-ResponseChannels $script:channels)) {
    $script:channels = Copy-Channels $script:savedChannels
    $script:channelIndex = if ($script:channels.Count -eq 0) { -1 } else { 0 }
    $discardedDraft = $true
  }
  $modelsPage.Visibility = "Visible"
  $modelsCard.Visibility = "Visible"
  $proxyPage.Visibility = "Collapsed"
  $agentsPage.Visibility = "Collapsed"
  $appearancePage.Visibility = "Collapsed"
  Set-Nav "models"
  $listPage.Visibility = "Visible"
  $detailPage.Visibility = "Collapsed"
  $simplePage.Visibility = "Collapsed"
  $aboutPage.Visibility = "Collapsed"
  $script:modelEditorActive = $false
  # 离开编辑页这个标记就不成立了：列表上的动作（删渠道等）不能拿它去改「运行中」是谁。
  $script:editingCurrent = $false
  # 回到列表就等于离开编辑页，编辑页的未保存提示不能挂到这里。
  Set-Feedback $(if ($discardedDraft) { "未完成的渠道草稿已丢弃" } else { "" }) $discardedDraft
  Update-ChannelList
  Update-Controls
}

function Show-Proxy-Page {
  $listPage.Visibility = "Visible"
  $detailPage.Visibility = "Collapsed"
  $simplePage.Visibility = "Collapsed"
  $aboutPage.Visibility = "Collapsed"
  $modelsPage.Visibility = "Collapsed"
  $modelsCard.Visibility = "Collapsed"
  $proxyPage.Visibility = "Visible"
  $agentsPage.Visibility = "Collapsed"
  $appearancePage.Visibility = "Collapsed"
  Set-Nav "proxy"
  $script:proxyHost = [string]$script:proxyHost
  $script:proxyPort = [string]$script:proxyPort
  $script:rendering = $true
  $proxyHostField.Text = [string]$script:proxyHost
  $proxyPortField.Text = [string]$script:proxyPort
  $script:rendering = $false
  Set-Feedback $(if (Test-ProxyDirty) { "代理配置有未保存的更改" } else { "" })
  Update-Controls
}

function Test-ProxyDirty {
  return [string]$script:proxyHost -ne [string]$script:savedProxyHost -or `
    [string]$script:proxyPort -ne [string]$script:savedProxyPort
}

function Show-Detail-Page {
  $modelsPage.Visibility = "Visible"
  $modelsCard.Visibility = "Visible"
  $proxyPage.Visibility = "Collapsed"
  $agentsPage.Visibility = "Collapsed"
  $appearancePage.Visibility = "Collapsed"
  Set-Nav "models"
  $listPage.Visibility = "Collapsed"
  $detailPage.Visibility = "Visible"
  $simplePage.Visibility = "Collapsed"
  $aboutPage.Visibility = "Collapsed"
  $script:modelEditorActive = $true
  # 进编辑页这一刻记下「这条是不是正在运行的那条」：后面把 Provider ID 改掉之后就比不出来了。
  $active = Get-ActiveChannel
  $script:editingCurrent = $null -ne $active -and -not [string]::IsNullOrWhiteSpace([string]$active.id) -and `
    [string]$active.id -eq [string]$script:currentChannelId
  Update-ChannelFields
  Rebuild-Rows
  Update-Controls
}

function Show-Empty-Page([string]$Title, [string]$Section) {
  $listPage.Visibility = "Collapsed"
  $detailPage.Visibility = "Collapsed"
  $simplePage.Visibility = "Visible"
  $aboutPage.Visibility = "Collapsed"
  $agentsPage.Visibility = "Collapsed"
  $appearancePage.Visibility = "Collapsed"
  $simplePageTitle.Text = $Title
  Set-Nav $Section
  Set-Feedback ""
}

function Test-AgentsDirty {
  return [string]$script:agentsContent -ne [string]$script:savedAgentsContent -or `
    [bool]$script:agentsEnabled -ne [bool]$script:savedAgentsEnabled
}

function Update-AgentsControls {
  $agentsContentField.IsEnabled = -not $script:busy
  $agentsEnabledToggle.IsEnabled = -not $script:busy
  $saveAgentsButton.IsEnabled = $script:loaded -and -not $script:busy -and (Test-AgentsDirty)
  $agentsBackupLabel.Text = if ($script:agentsBackupPath) { "最近备份：$script:agentsBackupPath" } else { "" }
  $agentsErrorLabel.Text = [string]$script:agentsError
}

function Refresh-Agents-View {
  $script:rendering = $true
  $agentsContentField.Text = [string]$script:agentsContent
  $agentsEnabledToggle.IsChecked = [bool]$script:agentsEnabled
  $script:rendering = $false
  Set-Nav "agents"
  Update-AgentsControls
}

# 离开或关闭前统一确认 Agents 草稿；确认后同步清空内部状态和可见编辑框。
function Confirm-AgentsDiscard([string]$Message) {
  if ($script:savingAgents) {
    [System.Windows.MessageBox]::Show(
      $window,
      "请等待公共指令保存完成后再关闭或退出。",
      "正在保存公共指令",
      "OK", "Information") | Out-Null
    return $false
  }
  if (-not (Test-AgentsDirty)) { return $true }
  $answer = [System.Windows.MessageBox]::Show(
    $window,
    $Message,
    "放弃未保存的更改？",
    "YesNo", "Warning")
  if ($answer -ne "Yes") { return $false }
  $script:agentsContent = [string]$script:savedAgentsContent
  $script:agentsEnabled = $script:savedAgentsEnabled
  Refresh-Agents-View
  Set-Feedback ""
  return $true
}

function Confirm-AgentsLeave {
  # 保存期间留在当前页，防止迟到的回包把用户从刚切换的页面拉回来。
  if ($script:savingAgents) { return $false }
  return Confirm-AgentsDiscard "Agents 里还有未保存的改动，离开会丢弃它们。"
}

function Show-Agents-Page {
  $listPage.Visibility = "Collapsed"
  $detailPage.Visibility = "Collapsed"
  $simplePage.Visibility = "Collapsed"
  $aboutPage.Visibility = "Collapsed"
  $agentsPage.Visibility = "Visible"
  $appearancePage.Visibility = "Collapsed"
  Set-Feedback ""
  Refresh-Agents-View
}

function Set-Appearance-Image([System.Windows.Controls.Image]$Target, [string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue) -or -not (Test-Path -LiteralPath $PathValue)) {
    $Target.Source = $null
    return
  }
  try {
    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = New-Object System.Uri($PathValue, [System.UriKind]::Absolute)
    $bitmap.EndInit()
    $bitmap.Freeze()
    $Target.Source = $bitmap
  } catch {
    $Target.Source = $null
  }
}

# 让顶部预览容器跟随 1400×875 源图比例，Image 的 UniformToFill 只负责铺满同比例区域。
function Update-AppearancePreviewAspect {
  if ($null -eq $appearancePreviewFrame -or $appearancePreviewFrame.ActualWidth -le 0) { return }
  $targetHeight = [Math]::Round($appearancePreviewFrame.ActualWidth * 875.0 / 1400.0, 2)
  if ([Math]::Abs([double]$appearancePreviewFrame.Height - $targetHeight) -gt 0.5) {
    $appearancePreviewFrame.Height = $targetHeight
  }
}

if ($null -ne $appearancePreviewFrame) {
  $appearancePreviewFrame.Add_SizeChanged({
    param($sender, $eventArgs)
    Update-AppearancePreviewAspect
  })
}

function Apply-Appearance-State($Value) {
  if ($null -eq $Value) { return }
  if ($Value.theme) { $script:appearanceTheme = [string]$Value.theme }
  $script:appearanceFollowNative = $Value.followNative -eq $true
  $script:appearanceNativeMode = if ($Value.nativeMode -eq "dark") { "dark" } else { "light" }
  if ($null -ne $Value.themes) { $script:appearanceThemes = @($Value.themes) }
}

function New-Appearance-Theme-Card($Theme) {
  $cell = New-Object System.Windows.Controls.StackPanel
  $cell.Width = 118
  $cell.Margin = "0,0,10,14"

  $preview = New-Object System.Windows.Controls.Image
  $preview.Stretch = [System.Windows.Media.Stretch]::UniformToFill
  $preview.SetValue(
    [System.Windows.Media.RenderOptions]::BitmapScalingModeProperty,
    [System.Windows.Media.BitmapScalingMode]::HighQuality
  )
  Set-Appearance-Image $preview ([string]$Theme.coverPath)

  $selected = [string]$Theme.id -eq [string]$script:appearanceTheme
  $frame = New-Object System.Windows.Controls.Border
  $frame.Width = 112
  $frame.Height = 75
  $frame.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList 10
  $frame.ClipToBounds = $true
  $borderWidth = if ($selected) { 2 } else { 1 }
  $frame.BorderThickness = New-Object System.Windows.Thickness -ArgumentList $borderWidth
  $frame.BorderBrush = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]::FromRgb(220, 228, 218))
  $frame.Background = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]::FromRgb(240, 244, 240))
  if (-not [string]::IsNullOrWhiteSpace([string]$Theme.cardBackground)) {
    $cardColor = [System.Windows.Media.ColorConverter]::ConvertFromString([string]$Theme.cardBackground)
    $frame.Background = New-Object System.Windows.Media.SolidColorBrush -ArgumentList $cardColor
  }
  if ($selected) {
    $frame.BorderBrush = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]::FromRgb(59, 113, 78))
  }
  $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
  $shadow.BlurRadius = if ($selected) { 7 } else { 4 }
  $shadow.ShadowDepth = 2
  $shadow.Direction = 270
  $shadow.Opacity = if ($selected) { 0.12 } else { 0.07 }
  $frame.Effect = $shadow

  $overlay = New-Object System.Windows.Controls.Grid
  [void]$overlay.Children.Add($preview)
  if ($selected) {
    $check = New-Object System.Windows.Controls.Border
    $check.Width = 18
    $check.Height = 18
    $check.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList 9
    $check.Background = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]::FromRgb(51, 107, 64))
    $check.HorizontalAlignment = "Right"
    $check.VerticalAlignment = "Top"
    $check.Margin = "0,8,8,0"
    $checkText = New-Object System.Windows.Controls.TextBlock
    $checkText.Text = "✓"
    $checkText.Foreground = [System.Windows.Media.Brushes]::White
    $checkText.FontSize = 11
    $checkText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $checkText.HorizontalAlignment = "Center"
    $checkText.VerticalAlignment = "Center"
    $check.Child = $checkText
    [void]$overlay.Children.Add($check)
  }
  $frame.Child = $overlay

  $button = New-Object System.Windows.Controls.Button
  $button.Style = $window.FindResource("ThemeCard")
  $button.Width = 118
  $button.Height = 75
  $button.Padding = New-Object System.Windows.Thickness -ArgumentList 0
  $button.Background = [System.Windows.Media.Brushes]::Transparent
  $button.BorderThickness = New-Object System.Windows.Thickness -ArgumentList 0
  $button.Content = $frame
  $button.Tag = [string]$Theme.id
  $button.ToolTip = "使用「$([string]$Theme.name)」主题"
  $button.IsEnabled = $script:loaded -and -not $script:busy
  [System.Windows.Automation.AutomationProperties]::SetName($button, "使用「$([string]$Theme.name)」主题")
  $button.Add_Click({ param($sender, $eventArgs) Select-Appearance-Theme ([string]$sender.Tag) })
  [void]$cell.Children.Add($button)

  $name = New-Object System.Windows.Controls.TextBlock
  $name.Text = [string]$Theme.name
  $name.FontSize = 12
  $name.TextAlignment = "Center"
  $name.TextTrimming = "CharacterEllipsis"
  $name.Margin = "2,5,2,0"
  $name.Foreground = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]::FromRgb(32, 37, 34))
  if ($selected) { $name.FontWeight = [System.Windows.FontWeights]::SemiBold }
  [void]$cell.Children.Add($name)
  return $cell
}

function Refresh-Appearance-View {
  Update-AppearancePreviewAspect
  $themes = @($script:appearanceThemes)
  $selected = $themes | Where-Object { [string]$_.id -eq [string]$script:appearanceTheme } | Select-Object -First 1
  $appearancePreviewEmpty.Visibility = "Collapsed"
  if ($selected) {
    Set-Appearance-Image $appearancePreviewImage ([string]$selected.previewPath)
    if ($null -eq $appearancePreviewImage.Source) {
      $appearancePreviewEmptyText.Text = "主题预览不可用"
      $appearancePreviewEmpty.Visibility = "Visible"
    } else {
      $previewColor = if ([string]$selected.colorScheme -eq "dark") { "#25282C" } else { "#EEF2ED" }
      $appearancePreviewFrame.Background = New-Object System.Windows.Media.SolidColorBrush -ArgumentList (
        [System.Windows.Media.ColorConverter]::ConvertFromString($previewColor))
    }
  } else {
    $appearancePreviewImage.Source = $null
    $appearancePreviewEmptyText.Text = if ($script:loaded) { "主题资源不可用" } else { "正在读取主题…" }
    $appearancePreviewEmpty.Visibility = "Visible"
  }
  $appearanceBusyOverlay.Visibility = if ($script:savingAppearance) { "Visible" } else { "Collapsed" }
  $appearanceThemePanel.Children.Clear()
  if ($themes.Count -eq 0) {
    $emptyThemeText = New-Object System.Windows.Controls.TextBlock
    $emptyThemeText.Text = if ($script:loaded) { "主题资源不可用" } else { "正在读取主题…" }
    $emptyThemeText.FontSize = 12
    $emptyThemeText.Foreground = New-Object System.Windows.Media.SolidColorBrush -ArgumentList (
      [System.Windows.Media.Color]::FromRgb(116, 125, 118))
    $emptyThemeText.Margin = "0,4,0,10"
    [void]$appearanceThemePanel.Children.Add($emptyThemeText)
  }
  foreach ($theme in $themes) {
    [void]$appearanceThemePanel.Children.Add((New-Appearance-Theme-Card $theme))
  }
  if ($themes.Count -gt 0) {
    $coming = New-Object System.Windows.Controls.StackPanel
    $coming.Width = 118
    $coming.Margin = "0,0,10,14"
    $placeholder = New-Object System.Windows.Controls.Border
    $placeholder.Width = 112
    $placeholder.Height = 75
    $placeholder.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList 10
    $placeholder.Background = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]::FromRgb(241, 241, 241))
    $placeholder.BorderBrush = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]::FromRgb(232, 232, 232))
    $placeholder.BorderThickness = New-Object System.Windows.Thickness -ArgumentList 1
    $placeholderText = New-Object System.Windows.Controls.TextBlock
    $placeholderText.Text = "敬请期待"
    $placeholderText.FontSize = 12
    $placeholderText.Foreground = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]::FromRgb(160, 160, 160))
    $placeholderText.HorizontalAlignment = "Center"
    $placeholderText.VerticalAlignment = "Center"
    $placeholder.Child = $placeholderText
    [void]$coming.Children.Add($placeholder)
    [void]$appearanceThemePanel.Children.Add($coming)
  }
  Update-AppearancePreviewAspect
  Update-Controls
}

function Select-Appearance-Theme([string]$ThemeId) {
  if (-not $script:loaded -or $script:busy -or $script:savingAppearance) { return }
  $theme = @($script:appearanceThemes) | Where-Object { [string]$_.id -eq $ThemeId } | Select-Object -First 1
  if (-not $theme -or (
    -not $script:appearanceFollowNative -and
    [string]$script:appearanceTheme -eq $ThemeId
  )) { return }
  $script:appearanceThemeBeforeSave = [string]$script:appearanceTheme
  $script:appearanceFollowNativeBeforeSave = $script:appearanceFollowNative
  $script:appearanceNativeModeBeforeSave = [string]$script:appearanceNativeMode
  $script:appearanceTheme = $ThemeId
  $script:appearanceFollowNative = $false
  $script:savingAppearance = $true
  $script:busy = $true
  Set-Feedback "正在应用「$([string]$theme.name)」…"
  Refresh-Appearance-View
  Send-Request @{
    action = "save"
    restart = $false
    scope = "appearance"
    theme = $ThemeId
  }
}

function Show-Appearance-Page {
  $listPage.Visibility = "Collapsed"
  $detailPage.Visibility = "Collapsed"
  $simplePage.Visibility = "Collapsed"
  $aboutPage.Visibility = "Collapsed"
  $agentsPage.Visibility = "Collapsed"
  $appearancePage.Visibility = "Visible"
  Set-Nav "appearance"
  Set-Feedback ""
  Refresh-Appearance-View
}

function Show-About-Page {
  $listPage.Visibility = "Collapsed"
  $detailPage.Visibility = "Collapsed"
  $simplePage.Visibility = "Collapsed"
  $aboutPage.Visibility = "Visible"
  $agentsPage.Visibility = "Collapsed"
  $appearancePage.Visibility = "Collapsed"
  Set-Nav "about"
  Set-Feedback ""
}

function Update-Controls {
  $hasChannel = $null -ne (Get-ActiveChannel)
  $models = Get-ActiveModels
  $addChannelButton.IsEnabled = $script:loaded -and -not $script:busy -and $script:channels.Count -lt 50
  $deleteChannelButton.IsEnabled = $script:loaded -and -not $script:busy -and $hasChannel
  $deleteChannelButton.ToolTip = "删除渠道"
  $backButton.IsEnabled = -not $script:busy
  foreach ($field in @($channelIdField, $channelBaseUrlField, $channelApiKeyField, $channelHeaderNameField, $channelHeaderValueField)) {
    $field.IsEnabled = $script:loaded -and -not $script:busy -and $hasChannel
  }
  $clearButton.IsEnabled = $script:loaded -and -not $script:busy
  $restartButton.IsEnabled = $script:loaded -and -not $script:busy
  $proxyRestartButton.IsEnabled = $restartButton.IsEnabled
  $agentsRestartButton.IsEnabled = $restartButton.IsEnabled
  $appearanceRestartButton.IsEnabled = $restartButton.IsEnabled
  $dirty = Compare-Channels $script:channels $script:savedChannels
  # 「保存」只写渠道文件；把改动写进 ChatGPT 是右上角那个「重启」的事，按钮文案不再跟着变。
  $saveButton.Content = "保存"
  $saveButton.IsEnabled = $script:loaded -and -not $script:busy -and $dirty
  # 没填地址就问不动端点，所以按钮跟着地址一起灰。
  $fetchModelsButton.Content = if ($script:fetchingModels) { "获取中…" } else { "获取可用模型" }
  $fetchModelsButton.IsEnabled = $script:loaded -and -not $script:busy -and $hasChannel -and -not [string]::IsNullOrWhiteSpace([string](Get-ActiveChannel).baseUrl)
  $emptyState.Visibility = if ($script:loaded -and $models.Count -eq 0) { "Visible" } else { "Collapsed" }
  $proxyHostField.IsEnabled = $script:loaded -and -not $script:busy
  $proxyPortField.IsEnabled = $script:loaded -and -not $script:busy
  $saveProxyButton.IsEnabled = $script:loaded -and -not $script:busy -and (Test-ProxyDirty)
}

function Compare-Channels($Left, $Right) {
  if ($Left.Count -ne $Right.Count) { return $true }
  for ($index = 0; $index -lt $Left.Count; $index++) {
    foreach ($field in @("id", "name", "baseUrl", "apiKey", "headerName", "headerValue", "enabled")) {
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
    if ($Left[$index].supportsSearchTool -ne $Right[$index].supportsSearchTool) { return $true }
  }
  return $false
}

# 把注入器返回的渠道数组转成面板使用的哈希表。
function Convert-ResponseChannels($Source) {
  # 一元逗号阻止单元素数组被管道展开成 Hashtable，列表必须始终拿到数组。
  return ,@($Source | ForEach-Object {
    @{
      id = [string]$_.id
      name = [string]$_.name
      baseUrl = [string]$_.baseUrl
      apiKey = [string]$_.apiKey
      headerName = [string]$_.headerName
      headerValue = [string]$_.headerValue
      enabled = $_.enabled -ne $false
      models = @($_.models | ForEach-Object {
        @{
          id = [string]$_.id; displayName = [string]$_.displayName
          context = [int]$_.context; inputModalities = @($_.inputModalities)
          supportsSearchTool = $_.supportsSearchTool -eq $true
          supportsParallelToolCalls = $true
        }
      })
    }
  })
}

# 成功响应里的渠道必须有非空 ID；结构不对时保留当前面板，不让空 ID 卡片覆盖正常列表。
function Test-ResponseChannels($Source) {
  if ($null -eq $Source) { return $false }
  $items = @($Source)
  foreach ($item in $items) {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.id)) { return $false }
  }
  return $true
}

# 渠道是哈希表，直接赋值会共用同一份对象，改动会串到另一份上；这里逐层复制。
function Copy-Channels($Source) {
  return ,@($Source | ForEach-Object {
    @{
      id = $_.id; name = $_.name; baseUrl = $_.baseUrl; apiKey = $_.apiKey
      headerName = $_.headerName; headerValue = $_.headerValue
      # 少了这一项，复制出来的快照会丢掉禁用状态：返回后禁用过的渠道会被当成启用。
      enabled = $_.enabled -ne $false
      models = @($_.models | ForEach-Object {
        @{
          id = $_.id; displayName = $_.displayName
          context = $_.context; inputModalities = @($_.inputModalities)
          supportsSearchTool = $_.supportsSearchTool -eq $true
          supportsParallelToolCalls = $true
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
  $script:modelSizeTexts = @()
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
    $idBox.IsReadOnly = $true
    $idBox.HorizontalAlignment = "Stretch"
    [void]$content.Children.Add((New-ModelFieldBlock "模型 ID" @($idBox)))

    # 客户端按模型 ID 发请求、按显示名称渲染选择器：名字只影响列表里怎么显示。
    $nameBox = New-ModelBox @{ index = $index; field = "displayName" } ([string]$model.displayName) 300
    $nameBox.HorizontalAlignment = "Stretch"
    [void]$content.Children.Add((New-ModelFieldBlock "显示名称" @($nameBox)))

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
    $script:modelSizeTexts += $sizeText
    $contextRow = New-Object System.Windows.Controls.StackPanel
    $contextRow.Orientation = "Horizontal"
    [void]$contextRow.Children.Add($contextBlock)
    [void]$contextRow.Children.Add($sizeText)
    [void]$content.Children.Add($contextRow)

    $modalityLabel = New-Object System.Windows.Controls.TextBlock
    $modalityLabel.Text = "输入类型与能力"
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
    $capabilityRow = New-Object System.Windows.Controls.StackPanel
    $capabilityRow.Orientation = "Horizontal"
    $capabilityRow.Margin = "0,8,0,0"
    foreach ($capability in @(
      @{ field = "supportsSearchTool"; label = "网页搜索"; value = $model.supportsSearchTool }
    )) {
      $check = New-Object System.Windows.Controls.CheckBox
      $check.Content = $capability.label
      $check.FontSize = 14
      $check.IsEnabled = $enabled
      $check.Tag = @{ index = $index; field = $capability.field }
      $check.IsChecked = $capability.value -eq $true
      $check.Margin = "0"
      $check.Add_Click({ param($sender, $eventArgs) Toggle-ToolCapability $sender })
      [void]$capabilityRow.Children.Add($check)
    }
    [void]$content.Children.Add($capabilityRow)

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
        # 「约 Nk」按行下标存着：卡片里的字段会增减，按 Children 下标找会错位。
        if ($index -lt $script:modelSizeTexts.Count) {
          $script:modelSizeTexts[$index].Text = "约 $(Convert-Context $value)"
        }
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

function Toggle-ToolCapability($Sender) {
  if ($script:rendering -or $script:busy) { return }
  $channel = Get-ActiveChannel
  if (-not $channel) { return }
  $index = [int]$Sender.Tag.index
  if ($index -lt 0 -or $index -ge $channel.models.Count) { return }
  $channel.models[$index].($Sender.Tag.field) = $Sender.IsChecked -eq $true
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

# 端点清单先弹卡片勾选，点「导入所选」才进模型目录。
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

# 只刷「全选」和「导入所选」的状态，不重建列表，免得勾一下就丢焦点。
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

# 勾上的补进当前渠道；已有模型只应用端点明确返回的能力，保留人工设置的名字和窗口。
function Add-SelectedModels {
  $channel = Get-ActiveChannel
  if (-not $channel) { Hide-ModelPicker; Update-Controls; return }
  $existing = @{}
  foreach ($model in @($channel.models)) { $existing[[string]$model.id] = $model }
  $added = 0
  $updated = 0
  foreach ($row in $script:discoveredModels) {
    $id = [string]$row.id
    if (-not $script:discoveredSelection.ContainsKey($id)) { continue }
    if ($existing.ContainsKey($id)) {
      $model = $existing[$id]
      $hasCapabilities = $false
      foreach ($field in @("supportsSearchTool")) {
        if (@($row.PSObject.Properties.Name) -contains $field -and $null -ne $row.$field) {
          $model[$field] = [bool]$row.$field
          $hasCapabilities = $true
        }
      }
      if ($hasCapabilities) { $updated += 1 }
      continue
    }
    $model = @{
      id = $id
      displayName = [string]$row.displayName
      context = $(if ($null -ne $row.context) { [int]$row.context } else { 272 })
      inputModalities = @("text", "image")
      supportsSearchTool = $row.supportsSearchTool -eq $true
      supportsParallelToolCalls = $true
    }
    $channel.models = @($channel.models) + $model
    $existing[$id] = $model
    $added += 1
  }
  Hide-ModelPicker
  Rebuild-Rows
  $message = if ($updated -gt 0) {
    $addedText = if ($added -gt 0) { "添加 $added 个、" } else { "" }
    "已${addedText}更新 $updated 个模型，点「保存」后生效"
  } elseif ($added -gt 0) {
    "已添加 $added 个模型，点「保存」后生效"
  } else {
    "端点没有返回新的模型或能力"
  }
  Set-Feedback $message
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

function Get-ChannelIdError([string]$Value) {
  $id = ([string]$Value).Trim()
  if (-not $id) { return "渠道 ID 不能为空" }
  if ($id.Length -gt 32) { return "渠道 ID 不能超过 32 个字符" }
  if ($id -notmatch '^[A-Za-z0-9_-]+$') { return "渠道 ID 只能用字母、数字、- 和 _" }
  return $null
}

function Update-ChannelIdHint {
  $error = Get-ChannelIdError $channelIdField.Text
  $channelIdHint.Text = if ($error) { $error } else { "" }
  $channelIdHint.Visibility = if ($error) { "Visible" } else { "Collapsed" }
}

function Update-ChannelField([string]$Field, [string]$Value) {
  if ($script:rendering -or $script:busy) { return }
  $channel = Get-ActiveChannel
  if (-not $channel) { return }
  # 渠道 ID 落盘前会被 trim，面板里也按 trim 后的值存：不然后台认不出「运行中」还是同一条。
  if ($Field -eq "id") { $Value = $Value.Trim() }
  $channel[$Field] = $Value
  if ($Field -eq "id") {
    $pageTitle.Text = if ([string]::IsNullOrWhiteSpace($Value)) { "添加渠道" } else { $Value }
    Update-ChannelIdHint
  }
  Set-Feedback $(if (Compare-Channels $script:channels $script:savedChannels) { "有未保存的更改" } else { "" })
  Update-Controls
}

function Receive-Response($Response) {
  if ($Response.version -and $Response.version -ne $script:currentVersion) {
    $script:currentVersion = [string]$Response.version
    Refresh-VersionLabel
  }
  if ($null -ne $Response.appearance) {
    Apply-Appearance-State $Response.appearance
    if ($Response.event -eq "appearance-updated") {
      Set-Feedback ""
      Refresh-Appearance-View
      return
    }
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
  if ($script:savingAppearance) {
    $script:savingAppearance = $false
    $script:busy = $false
    if ($Response.ok -eq $true -and $null -ne $Response.appearance) {
      if ($Response.restartRequired -eq $true) {
        Set-Feedback "主题已保存，重启 ChatGPT 后生效"
      } else {
        $selected = @($script:appearanceThemes) |
          Where-Object { [string]$_.id -eq [string]$script:appearanceTheme } |
          Select-Object -First 1
        $name = if ($selected) { [string]$selected.name } else { [string]$script:appearanceTheme }
        Set-Feedback "已切换到「$name」并应用到 ChatGPT"
      }
    } else {
      $script:appearanceTheme = [string]$script:appearanceThemeBeforeSave
      $script:appearanceFollowNative = $script:appearanceFollowNativeBeforeSave
      $script:appearanceNativeMode = [string]$script:appearanceNativeModeBeforeSave
      Set-Feedback $(if ($Response.error) { [string]$Response.error } else { "应用外观主题失败" }) $true
    }
    Refresh-Appearance-View
    return
  }
  if ($script:savingProxy) {
    $script:savingProxy = $false
    $script:busy = $false
    if ($Response.ok -eq $true -and $null -ne $Response.proxy) {
      $script:proxyHost = [string]$Response.proxy.host
      $script:proxyPort = [string]$Response.proxy.port
      $script:savedProxyHost = $script:proxyHost
      $script:savedProxyPort = $script:proxyPort
      Set-Feedback "代理配置已保存，重启 ChatGPT 后生效"
    } else {
      Set-Feedback $(if ($Response.error) { [string]$Response.error } else { "保存代理配置失败" }) $true
    }
    Show-Proxy-Page
    return
  }
  if ($script:savingAgents) {
    $script:savingAgents = $false
    $script:busy = $false
    if ($Response.ok -eq $true -and $null -ne $Response.agents) {
      $script:agentsContent = [string]$Response.agents.content
      $script:savedAgentsContent = $script:agentsContent
      $script:agentsSource = [string]$Response.agents.source
      $script:agentsBackupPath = [string]$Response.agents.backupPath
      $script:agentsError = ""
      $script:agentsEnabled = $Response.agents.enabled -eq $true
      $script:savedAgentsEnabled = $script:agentsEnabled
      Set-Feedback $(if ($script:agentsBackupPath) {
        "公共指令已同步，原文件已备份"
      } else {
        "公共指令已保存"
      })
    } else {
      Set-Feedback $(if ($Response.error) { [string]$Response.error } else { "保存公共指令失败" }) $true
    }
    # 只刷新 Agents 字段，保留刚写入的成功或错误提示。
    Refresh-Agents-View
    return
  }
  $script:busy = $false
  $ok = $Response.ok -eq $true
  $cleared = $Response.cleared -eq $true
  if ($ok -or $Response.saved -eq $true -or $cleared) {
    if ($null -ne $Response.proxy) {
      $script:proxyHost = [string]$Response.proxy.host
      $script:proxyPort = [string]$Response.proxy.port
      $script:savedProxyHost = $script:proxyHost
      $script:savedProxyPort = $script:proxyPort
    }
    if ($null -ne $Response.agents) {
      $script:agentsContent = [string]$Response.agents.content
      $script:savedAgentsContent = $script:agentsContent
      $script:agentsSource = [string]$Response.agents.source
      $script:agentsBackupPath = [string]$Response.agents.backupPath
      $script:agentsError = [string]$Response.agents.error
      $script:agentsEnabled = $Response.agents.enabled -eq $true
      $script:savedAgentsEnabled = $script:agentsEnabled
    }
    if (Test-ResponseChannels $Response.channels) {
      $keepAppearancePage = -not $script:loaded -and $appearancePage.Visibility -eq "Visible"
      $previousId = ""
      $active = Get-ActiveChannel
      if ($active) { $previousId = [string]$active.id }
      $script:channels = Convert-ResponseChannels $Response.channels
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
      if (($cleared -or $Response.restarted -eq $true -or $script:channelIndex -lt 0) -and
          -not $keepAppearancePage) {
        Show-List-Page
      } else {
        Update-ChannelList
      }
    } elseif ($ok -or $Response.saved -eq $true) {
      Set-Feedback "插件返回的渠道列表不完整，已保留当前配置" $true
    }
    if ($appearancePage.Visibility -eq "Visible") { Refresh-Appearance-View }
  }
  if (-not $ok) {
    # 删除没能存盘就把刚拿掉的那条放回去，别让面板和文件对不上。
    if ($script:pendingDeleteRestore) {
      $script:channels = $script:pendingDeleteRestore
      $script:channelIndex = if ($script:channels.Count -eq 0) { -1 } else { [Math]::Min($script:channelIndex, $script:channels.Count - 1) }
    }
    # 重新渲染列表，把正在启用的那一行放回「启用」。
    Update-ChannelList
    Set-Feedback $(if ($Response.error) { [string]$Response.error } else { "操作失败" }) $true
  } elseif ($cleared) {
    Set-Feedback "已清空并重启 ChatGPT"
  } elseif ($Response.restarted -eq $true) {
    Set-Feedback "配置已写入，ChatGPT 已重启"
  } elseif ($Response.saved -eq $true) {
    if (Test-ResponseChannels $Response.channels) {
      $successNote = if ($script:pendingDeleteNote) { $script:pendingDeleteNote } else { "已保存，点右上角「重启 ChatGPT」才会生效" }
      if ($script:modelEditorActive) { Show-List-Page }
      Set-Feedback $successNote
    } else {
      Set-Feedback "插件返回的渠道列表不完整，已保留当前配置" $true
    }
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

function Submit([string]$Action, [string]$Note = "", [string]$Current = "") {
  if (-not $script:loaded -or $script:busy) { return }
  $channel = Get-ActiveChannel
  # 保存整份列表不需要当前渠道（删掉最后一个之后也要能存）；「重启」也一样，后台自己挑渠道。
  $script:busy = $true
  Set-Feedback $(if ($Note) { $Note } elseif ($Action -eq "switch") { "正在重启 ChatGPT…" } else { "正在保存…" })
  Rebuild-Rows
  Update-Controls
  Send-Request @{
    action = $Action
    restart = ($Action -eq "switch")
    current = $(if ($Current) { $Current } else { [string]$script:currentChannelId })
    channels = @($script:channels | ForEach-Object {
      @{
        id = [string]$_.id; name = [string]$_.name; baseUrl = [string]$_.baseUrl
        apiKey = [string]$_.apiKey; headerName = [string]$_.headerName; headerValue = [string]$_.headerValue
        enabled = $_.enabled -ne $false
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

$saveButton.Add_Click({
  if (-not $script:loaded -or $script:busy) { return }
  # 保存只写渠道列表：写进 ChatGPT 是右上角「重启」的事。改的是正在用的那条时 current
  # 要跟着新 ID 走，否则把渠道 ID 改掉之后「运行中」就掉了。
  $channel = Get-ActiveChannel
  $idError = Get-ChannelIdError ([string]$channel.id)
  if ($idError) {
    Update-ChannelIdHint
    Set-Feedback $idError $true
    $channelIdField.Focus() | Out-Null
    return
  }
  if ($script:editingCurrent -and $null -ne $channel) { Submit "save" "" ([string]$channel.id); return }
  Submit "save"
})

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
        headerName = ""; headerValue = ""; enabled = $true; models = @()
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
$proxyHostField.Add_TextChanged({
  if ($script:rendering) { return }
  $script:proxyHost = [string]$proxyHostField.Text
  if ($script:savingProxy) { return }
  Set-Feedback $(if (Test-ProxyDirty) { "代理配置有未保存的更改" } else { "" })
  Update-Controls
})
$proxyPortField.Add_TextChanged({
  if ($script:rendering) { return }
  $script:proxyPort = [string]$proxyPortField.Text
  if ($script:savingProxy) { return }
  Set-Feedback $(if (Test-ProxyDirty) { "代理配置有未保存的更改" } else { "" })
  Update-Controls
})
$modelsTab.Add_Click({ if (Confirm-AgentsLeave) { Show-Models-Page } })
$proxyTab.Add_Click({ if (Confirm-AgentsLeave) { Show-Proxy-Page } })
$generalTab.Add_Click({ if (Confirm-AgentsLeave) { Show-Empty-Page "通用" "general" } })
$appearanceTab.Add_Click({ if (Confirm-AgentsLeave) { Show-Appearance-Page } })
$agentsTab.Add_Click({ Show-Agents-Page })

$agentsContentField.Add_TextChanged({
  if ($script:rendering -or $script:busy) { return }
  $script:agentsContent = $agentsContentField.Text
  Set-Feedback $(if (Test-AgentsDirty) { "有未保存的更改" } else { "" })
  Update-AgentsControls
})
$agentsEnabledToggle.Add_Click({
  if ($script:rendering -or $script:busy) { return }
  $script:agentsEnabled = $agentsEnabledToggle.IsChecked -eq $true
  Set-Feedback $(if (Test-AgentsDirty) { "有未保存的更改" } else { "" })
  Update-AgentsControls
})
$saveAgentsButton.Add_Click({
  if (-not $script:loaded -or $script:busy -or -not (Test-AgentsDirty)) { return }
  $script:busy = $true
  $script:savingAgents = $true
  Set-Feedback "正在保存公共指令…"
  Update-AgentsControls
  Send-Request @{
    action = "save"
    restart = $false
    scope = "agents"
    agents = @{
      content = [string]$script:agentsContent
      enabled = [bool]$script:agentsEnabled
    }
  }
})
$aboutTab.Add_Click({ if (Confirm-AgentsLeave) { Show-About-Page } })
$helpTab.Add_Click({ if (Confirm-AgentsLeave) { Show-Empty-Page "获取帮助" "help" } })
$saveProxyButton.Add_Click({
  if (-not $script:loaded -or $script:busy) { return }
  $port = 0
  if (-not [int]::TryParse([string]$script:proxyPort, [ref]$port)) { $port = -1 }
  $script:busy = $true
  $script:savingProxy = $true
  Set-Feedback "正在保存代理配置…"
  Update-Controls
  Send-Request @{
    action = "save"
    restart = $false
    scope = "proxy"
    proxy = @{ host = [string]$script:proxyHost; port = $port }
  }
})

# 模型、代理、Agents 和外观页的右上角入口共用同一重启流程，先确认再动手。
$requestRestart = {
  if (-not $script:loaded -or $script:busy) { return }
  $answer = [System.Windows.MessageBox]::Show(
    $window,
    "会重新写入 ChatGPT 配置和全部启用渠道的模型目录，然后重启客户端。",
    "重启 ChatGPT？",
    "OKCancel", "Warning")
  if ($answer -ne "OK") { return }
  Submit "switch"
}
$restartButton.Add_Click($requestRestart)
$proxyRestartButton.Add_Click($requestRestart)
$agentsRestartButton.Add_Click($requestRestart)
$appearanceRestartButton.Add_Click($requestRestart)

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
  if (-not (Confirm-AgentsDiscard "Agents 里还有未保存的改动，关闭面板会丢弃它们。")) {
    $eventArgs.Cancel = $true
    return
  }
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
  if (-not (Confirm-AgentsDiscard "Agents 里还有未保存的改动，退出会丢弃它们。")) { return }
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

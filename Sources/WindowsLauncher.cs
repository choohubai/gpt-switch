using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace GPTSwitch
{
    internal static class WindowsLauncher
    {
        private const string WindowTitle = "GPT Switch";
        private const int SwRestore = 9;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowW(string className, string windowName);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr handle, int command);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr handle);

        [STAThread]
        private static int Main(string[] args)
        {
            string installDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            Directory.SetCurrentDirectory(installDir);

            if (HasOption(args, "--stop"))
            {
                return StopInstalledProcesses(installDir) ? 0 : 1;
            }

            if (HasOption(args, "--message"))
            {
                string icon = OptionValue(args, "--message");
                string message = args.Length > 2 ? args[2] : "";
                ShowMessage(message, icon == "Error" ? MessageBoxIcon.Error : MessageBoxIcon.Warning);
                return 0;
            }

            if (HasOption(args, "--panel"))
            {
                int parentPid = ParseInteger(OptionValue(args, "--parent-pid"));
                string iconPath = OptionValue(args, "--icon-path") ?? "";
                return RunPanel(installDir, parentPid, iconPath);
            }

            if (HasOption(args, "--running-client-paths"))
            {
                ListProcesses(false, null);
                return 0;
            }

            if (HasOption(args, "--client-pids"))
            {
                string appPath = OptionValue(args, "--client-pids");
                if (String.IsNullOrEmpty(appPath))
                {
                    return 1;
                }
                ListProcesses(true, appPath);
                return 0;
            }

            if (HasOption(args, "--packaged-app"))
            {
                return PrintPackagedApp();
            }

            if (HasOption(args, "--activate-app"))
            {
                string activationId = OptionValue(args, "--activate-app");
                string activationArguments = OptionValueAt(args, "--activate-app", 2);
                return ActivatePackagedApp(activationId, activationArguments);
            }

            return LaunchInjector(installDir);
        }

        private static int LaunchInjector(string installDir)
        {
            if (ActivateExistingPanel(installDir))
            {
                return 0;
            }

            string injector = Path.Combine(installDir, "injector.mjs");
            if (!File.Exists(injector))
            {
                ShowMessage(
                    "GPT Switch 安装目录不完整，找不到 injector.mjs。\r\n\r\n请重新安装 GPT Switch。",
                    MessageBoxIcon.Error);
                return 1;
            }

            string node = FindNodeRuntime();
            if (String.IsNullOrEmpty(node))
            {
                ShowMessage(
                    "未找到 Node.js 运行时。\r\n\r\n请安装 ChatGPT/Codex 桌面端，或自行安装 Node.js 22 以上版本后重试。",
                    MessageBoxIcon.Warning);
                return 1;
            }

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = node,
                Arguments = QuoteArgument(injector),
                WorkingDirectory = installDir,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            try
            {
                Process.Start(startInfo);
                return 0;
            }
            catch (Exception error)
            {
                ShowMessage(
                    "启动 GPT Switch 失败：\r\n\r\n" + error.Message,
                    MessageBoxIcon.Error);
                return 1;
            }
        }

        private static int RunPanel(string installDir, int parentPid, string iconPath)
        {
            string panel = Path.Combine(installDir, "StatusMenu.ps1");
            if (!File.Exists(panel))
            {
                WriteError("找不到面板脚本：" + panel);
                return 1;
            }

            InitialSessionState state = InitialSessionState.CreateDefault();
            state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace runspace = RunspaceFactory.CreateRunspace(state))
            {
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell powershell = PowerShell.Create())
                {
                    powershell.Runspace = runspace;
                    powershell
                        .AddCommand(panel)
                        .AddParameter("ParentPid", parentPid)
                        .AddParameter("IconPath", iconPath);
                    try
                    {
                        powershell.Invoke();
                    }
                    catch (RuntimeException error)
                    {
                        WriteError(error.Message);
                        return 1;
                    }

                    if (powershell.HadErrors)
                    {
                        foreach (ErrorRecord error in powershell.Streams.Error)
                        {
                            WriteError(error.ToString());
                        }
                        return 1;
                    }
                }
            }
            return 0;
        }

        private static bool ActivateExistingPanel(string installDir)
        {
            IntPtr handle = FindWindowW(null, WindowTitle);
            if (handle == IntPtr.Zero)
            {
                return false;
            }

            Process owner = null;
            try
            {
                uint ownerPid;
                GetWindowThreadProcessId(handle, out ownerPid);
                owner = Process.GetProcessById((int)ownerPid);
                if (!String.Equals(owner.ProcessName, WindowTitle, StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                string ownerDirectory = Path.GetDirectoryName(owner.MainModule.FileName);
                if (!String.Equals(
                    Path.GetFullPath(ownerDirectory).TrimEnd('\\'),
                    Path.GetFullPath(installDir).TrimEnd('\\'),
                    StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
            }
            catch
            {
                return false;
            }
            finally
            {
                if (owner != null)
                {
                    owner.Dispose();
                }
            }

            ShowWindow(handle, SwRestore);
            SetForegroundWindow(handle);
            return true;
        }

        private static string FindNodeRuntime()
        {
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            List<string> runtimeDirs = new List<string>();
            string runtimeRoot = Path.Combine(localAppData, "OpenAI", "Codex", "runtimes", "cua_node");
            AddDirectories(runtimeDirs, runtimeRoot, "^.*$");
            AddDirectories(runtimeDirs, Path.Combine(localAppData, "Programs"), "^(Codex|ChatGPT)");
            foreach (string directory in runtimeDirs)
            {
                string node = directory.Contains(Path.DirectorySeparatorChar + "Programs" + Path.DirectorySeparatorChar)
                    ? Path.Combine(directory, "resources", "cua_node", "bin", "node.exe")
                    : Path.Combine(directory, "bin", "node.exe");
                if (File.Exists(node))
                {
                    return node;
                }
            }

            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string item in path.Split(Path.PathSeparator))
            {
                if (String.IsNullOrWhiteSpace(item))
                {
                    continue;
                }
                string candidate = Path.Combine(item.Trim(), "node.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            return null;
        }

        private static void AddDirectories(List<string> output, string root, string pattern)
        {
            try
            {
                if (!Directory.Exists(root))
                {
                    return;
                }
                List<DirectoryInfo> directories = new List<DirectoryInfo>();
                System.Text.RegularExpressions.Regex namePattern =
                    new System.Text.RegularExpressions.Regex(pattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                foreach (DirectoryInfo directory in new DirectoryInfo(root).GetDirectories())
                {
                    if (namePattern.IsMatch(directory.Name))
                    {
                        directories.Add(directory);
                    }
                }
                directories.Sort(delegate(DirectoryInfo left, DirectoryInfo right)
                {
                    return right.LastWriteTimeUtc.CompareTo(left.LastWriteTimeUtc);
                });
                foreach (DirectoryInfo directory in directories)
                {
                    output.Add(directory.FullName);
                }
            }
            catch
            {
                // A locked or disappearing client directory should not prevent later candidates.
            }
        }

        private static bool StopInstalledProcesses(string installDir)
        {
            int currentPid = Process.GetCurrentProcess().Id;
            bool stoppedAll = true;
            using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine FROM Win32_Process "
                + "WHERE Name = 'node.exe' OR Name = 'GPT Switch.exe' OR Name = 'powershell.exe'"))
            {
                foreach (ManagementObject item in searcher.Get())
                {
                    int processId = 0;
                    try
                    {
                        processId = Convert.ToInt32(item["ProcessId"]);
                        string commandLine = item["CommandLine"] as string;
                        if (processId == currentPid || String.IsNullOrEmpty(commandLine))
                        {
                            continue;
                        }
                        if (commandLine.IndexOf(installDir, StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            using (Process process = Process.GetProcessById(processId))
                            {
                                process.Kill();
                                if (!process.WaitForExit(5000))
                                {
                                    stoppedAll = false;
                                }
                            }
                        }
                    }
                    catch
                    {
                        if (processId > 0 && !IsProcessAlive(processId))
                        {
                            // The process may exit while the uninstaller is enumerating it.
                        }
                        else
                        {
                            stoppedAll = false;
                        }
                    }
                    finally
                    {
                        item.Dispose();
                    }
                }
            }
            return stoppedAll;
        }

        private static void ListProcesses(bool processIds, string appPath)
        {
            string name = processIds ? Path.GetFileName(appPath) : null;
            string query = processIds
                ? "SELECT ProcessId, Name, ExecutablePath FROM Win32_Process WHERE Name = '"
                    + name.Replace("'", "''") + "'"
                : "SELECT ProcessId, Name, ExecutablePath FROM Win32_Process "
                    + "WHERE Name = 'ChatGPT.exe' OR Name = 'Codex.exe'";
            using (StreamWriter output = new StreamWriter(
                Console.OpenStandardOutput(),
                new UTF8Encoding(false)))
            {
                output.AutoFlush = true;
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(query))
                {
                    foreach (ManagementObject item in searcher.Get())
                    {
                        try
                        {
                            string executablePath = item["ExecutablePath"] as string;
                            if (processIds)
                            {
                                if (!String.Equals(executablePath, appPath, StringComparison.OrdinalIgnoreCase))
                                {
                                    continue;
                                }
                                output.WriteLine(Convert.ToString(item["ProcessId"]));
                            }
                            else if (!String.IsNullOrEmpty(executablePath))
                            {
                                output.WriteLine(executablePath);
                            }
                        }
                        finally
                        {
                            item.Dispose();
                        }
                    }
                }
            }
        }

        private static int PrintPackagedApp()
        {
            // 桌面版（full-trust）的执行别名扩展自身也带 Executable 属性，不能把它过滤掉，
            // 否则永远找不到别名；有多个别名时优先挑真正存在于 WindowsApps 的那一个。
            string script = "$package = Get-AppxPackage OpenAI.Codex;"
                + " if ($package) {"
                + " $applications = @((Get-AppxPackageManifest $package).Package.Applications.Application);"
                + " $application = $applications | Where-Object { $_.Id -eq 'App' } | Select-Object -First 1;"
                + " if (-not $application) { $application = $applications"
                + " | Where-Object { $_.Executable } | Select-Object -First 1 };"
                + " $aliases = @($application.Extensions.Extension"
                + " | Where-Object { $_.Category -eq 'windows.appExecutionAlias' }"
                + " | ForEach-Object { [regex]::Match($_.InnerXml, 'Alias=\"([^\"]+)\"').Groups[1].Value }"
                + " | Where-Object { $_ });"
                + " $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\\WindowsApps';"
                + " $alias = $aliases | Where-Object { Test-Path (Join-Path $windowsApps $_) }"
                + " | Select-Object -First 1;"
                + " if (-not $alias -and $aliases.Count -gt 0) { $alias = $aliases[0] };"
                + " \"$($package.InstallLocation)|$($package.PackageFamilyName)!$($application.Id)"
                + "|$($application.Executable)|$alias\" }";
            InitialSessionState state = InitialSessionState.CreateDefault();
            state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace runspace = RunspaceFactory.CreateRunspace(state))
            {
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell powershell = PowerShell.Create())
                {
                    powershell.Runspace = runspace;
                    powershell.AddScript(script);
                    try
                    {
                        using (StreamWriter output = new StreamWriter(
                            Console.OpenStandardOutput(),
                            new UTF8Encoding(false)))
                        {
                            output.AutoFlush = true;
                            foreach (PSObject item in powershell.Invoke())
                            {
                                if (item != null)
                                {
                                    output.WriteLine(item.ToString());
                                }
                            }
                        }
                    }
                    catch (RuntimeException error)
                    {
                        WriteError(error.Message);
                        return 1;
                    }
                    if (powershell.HadErrors)
                    {
                        foreach (ErrorRecord error in powershell.Streams.Error)
                        {
                            WriteError(error.ToString());
                        }
                        return 1;
                    }
                }
            }
            return 0;
        }

        private static int ActivatePackagedApp(string activationId, string activationArguments)
        {
            if (String.IsNullOrEmpty(activationId))
            {
                return 1;
            }
            try
            {
                uint processId;
                IApplicationActivationManager manager =
                    (IApplicationActivationManager)new ApplicationActivationManager();
                int result = manager.ActivateApplication(
                    activationId,
                    activationArguments ?? "",
                    0,
                    out processId);
                Marshal.ThrowExceptionForHR(result);
                return 0;
            }
            catch (Exception error)
            {
                WriteError(error.Message);
                return 1;
            }
        }

        private static bool IsProcessAlive(int processId)
        {
            try
            {
                using (Process process = Process.GetProcessById(processId))
                {
                    return !process.HasExited;
                }
            }
            catch
            {
                return false;
            }
        }

        private static void WriteError(string message)
        {
            using (StreamWriter error = new StreamWriter(
                Console.OpenStandardError(),
                new UTF8Encoding(false)))
            {
                error.AutoFlush = true;
                error.WriteLine(message);
            }
        }

        private static void ShowMessage(string message, MessageBoxIcon icon)
        {
            MessageBox.Show(message, WindowTitle, MessageBoxButtons.OK, icon);
        }

        private static bool HasOption(string[] args, string name)
        {
            foreach (string argument in args)
            {
                if (String.Equals(argument, name, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            return false;
        }

        private static string OptionValue(string[] args, string name)
        {
            for (int index = 0; index < args.Length - 1; index++)
            {
                if (String.Equals(args[index], name, StringComparison.OrdinalIgnoreCase))
                {
                    return args[index + 1];
                }
            }
            return null;
        }

        private static string OptionValueAt(string[] args, string name, int offset)
        {
            for (int index = 0; index < args.Length; index++)
            {
                int valueIndex = index + offset;
                if (String.Equals(args[index], name, StringComparison.OrdinalIgnoreCase)
                    && valueIndex < args.Length)
                {
                    return args[valueIndex];
                }
            }
            return null;
        }

        private static int ParseInteger(string value)
        {
            int result;
            return Int32.TryParse(value, out result) ? result : 0;
        }

        private static string QuoteArgument(string value)
        {
            return "\"" + value + "\"";
        }

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);

        [ComImport]
        [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IApplicationActivationManager
        {
            [PreserveSig]
            int ActivateApplication(
                [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
                [MarshalAs(UnmanagedType.LPWStr)] string arguments,
                int options,
                out uint processId);

            [PreserveSig]
            int ActivateForFile(
                [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
                [MarshalAs(UnmanagedType.Interface)] object itemArray,
                [MarshalAs(UnmanagedType.LPWStr)] string verb,
                out uint processId);

            [PreserveSig]
            int ActivateForProtocol(
                [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
                [MarshalAs(UnmanagedType.Interface)] object itemArray,
                out uint processId);
        }

        [ComImport]
        [Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
        private class ApplicationActivationManager
        {
        }
    }
}

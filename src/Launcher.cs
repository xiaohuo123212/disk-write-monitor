// DiskWriteMonitor 启动器 —— 把采集引擎/看板/自启动安装器打包成单个 exe
// 编译: csc /target:winexe /out:DiskWriteMonitor.exe /win32icon:app.ico
//        /resource:engine.ps1,EngineScript /resource:dashboard.ps1,DashboardScript
//        /resource:installer.ps1,InstallerScript /resource:config.default.json,DefaultConfig Launcher.cs
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

internal static class Program
{
    private const string ProductName = "磁盘写入监视器";
    private const string AppVersion = "3.1";

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string mode = (args.Length > 0) ? args[0].ToLowerInvariant() : "gui";
            bool noUi = Array.IndexOf(args, "--no-ui") >= 0;
            _logRoot = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            Log("启动 mode=" + mode + " args=" + String.Join(" ", args) + " exeDir=" + _logRoot);
            string root = ResolveRoot();
            _logRoot = root;
            Log("root=" + root);
            Directory.CreateDirectory(root);

            string appDir = Path.Combine(root, "app");
            Directory.CreateDirectory(appDir);
            ExtractResources(appDir, root);

            string engine = Path.Combine(appDir, "DiskWriteMonitor.ps1");
            string dashboard = Path.Combine(appDir, "DiskWriteDashboard.ps1");
            string installer = Path.Combine(appDir, "Install-Autostart.ps1");
            string config = Path.Combine(root, "config.json");
            string exe = Assembly.GetExecutingAssembly().Location;

            switch (mode)
            {
                case "gui":
                case "--gui":
                case "":
                    return RunPowerShell("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + dashboard +
                        "\" -Root \"" + root + "\" -ConfigPath \"" + config + "\"", root, false);

                case "--engine":
                case "engine":
                    return RunPowerShell("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + engine +
                        "\" -Root \"" + root + "\" -ConfigPath \"" + config + "\"", root, false);

                case "--autostart":
                    // 开机自启: 先把引擎拉起来(不等它), 再正常打开面板(可见)
                    StartEngineDetached(root, engine, config);
                    return RunPowerShell("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + dashboard +
                        "\" -Root \"" + root + "\" -ConfigPath \"" + config + "\"", root, false);

                case "--tray":
                    return RunPowerShell("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + dashboard +
                        "\" -Root \"" + root + "\" -ConfigPath \"" + config + "\" -StartHidden", root, false);

                case "--archive":
                case "archive":
                    return RunPowerShell("-NoProfile -ExecutionPolicy Bypass -File \"" + engine +
                        "\" -Root \"" + root + "\" -ConfigPath \"" + config + "\" -ArchiveOnly", root, true);

                case "--install":
                case "--uninstall":
                case "--status":
                    string action = (mode == "--install") ? "Install" : (mode == "--uninstall" ? "Uninstall" : "Status");
                    string output = CapturePowerShell("-NoProfile -ExecutionPolicy Bypass -File \"" + installer +
                        "\" -Action " + action + " -Root \"" + root + "\" -ExePath \"" + exe + "\"", root);
                    ShowInfo(output, root, noUi);
                    return 0;

                case "--stop":
                    StopEngine(root);
                    ShowInfo("已请求停止引擎。", root, noUi);
                    return 0;

                case "--version":
                case "-v":
                    ShowInfo(ProductName + " " + AppVersion + "\n数据目录: " + root, root, noUi);
                    return 0;

                default:
                    ShowInfo("用法:\n" +
                        "  DiskWriteMonitor.exe              打开看板（默认）\n" +
                        "  DiskWriteMonitor.exe --engine     后台采集（供计划任务调用）\n" +
                        "  DiskWriteMonitor.exe --install    安装开机自启动\n" +
                        "  DiskWriteMonitor.exe --uninstall  移除开机自启动\n" +
                        "  DiskWriteMonitor.exe --status     查看自启动与引擎状态\n" +
                        "  DiskWriteMonitor.exe --autostart  开机自启（引擎+托盘界面）\n" +
                        "  DiskWriteMonitor.exe --tray       只以托盘方式启动界面\n" +
                        "  DiskWriteMonitor.exe --archive    立即执行一次归档\n" +
                        "  DiskWriteMonitor.exe --stop       停止正在运行的引擎\n" +
                        "  DiskWriteMonitor.exe --version    版本信息", root, noUi);
                    return 0;
            }
        }
        catch (Exception ex)
        {
            Log("异常: " + ex.ToString());
            ShowInfo("启动失败:\n" + ex.Message, Environment.CurrentDirectory, false);
            return 1;
        }
    }

    // ---------- 日志 ----------
    private static string _logRoot = "";

    private static void Log(string message)
    {
        try
        {
            string dir = _logRoot;
            if (String.IsNullOrEmpty(dir))
            {
                dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            }
            string dataDir = Path.Combine(dir, "data");
            Directory.CreateDirectory(dataDir);
            File.AppendAllText(Path.Combine(dataDir, "launcher.log"),
                "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + message + Environment.NewLine,
                new UTF8Encoding(true));
        }
        catch { }
    }

    // ---------- 路径 ----------
    private static string ResolveRoot()
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        try
        {
            string probe = Path.Combine(dir, ".dwm-write-test");
            File.WriteAllText(probe, "x");
            File.Delete(probe);
            return dir;
        }
        catch
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                "DiskWriteMonitor");
        }
    }

    // ---------- 释放内嵌资源 ----------
    private static void ExtractResources(string appDir, string root)
    {
        var asm = Assembly.GetExecutingAssembly();
        WriteIfChanged(asm, "EngineScript", Path.Combine(appDir, "DiskWriteMonitor.ps1"));
        WriteIfChanged(asm, "DashboardScript", Path.Combine(appDir, "DiskWriteDashboard.ps1"));
        WriteIfChanged(asm, "InstallerScript", Path.Combine(appDir, "Install-Autostart.ps1"));
        WriteIfChanged(asm, "AppIcon", Path.Combine(appDir, "app.ico"));

        string cfg = Path.Combine(root, "config.json");
        if (!File.Exists(cfg))
        {
            using (Stream s = asm.GetManifestResourceStream("DefaultConfig"))
            {
                if (s != null)
                {
                    using (var reader = new StreamReader(s, Encoding.UTF8))
                    {
                        File.WriteAllText(cfg, reader.ReadToEnd(), new UTF8Encoding(true));
                    }
                }
            }
        }
    }

    private static void WriteIfChanged(Assembly asm, string resource, string path)
    {
        using (Stream s = asm.GetManifestResourceStream(resource))
        {
            if (s == null) return;
            byte[] data = new byte[s.Length];
            int read = 0, total = 0;
            while ((total = s.Read(data, read, data.Length - read)) > 0) read += total;

            if (File.Exists(path))
            {
                byte[] old = File.ReadAllBytes(path);
                if (old.Length == data.Length)
                {
                    bool same = true;
                    for (int i = 0; i < data.Length; i++) { if (old[i] != data[i]) { same = false; break; } }
                    if (same) return;
                }
            }
            File.WriteAllBytes(path, data);
        }
    }

    // ---------- 进程 ----------
    private static ProcessStartInfo BuildPsi(string arguments, string root, bool capture)
    {
        var psi = new ProcessStartInfo("powershell.exe", arguments);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = root;
        if (capture)
        {
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;
        }
        return psi;
    }

    private static void StartEngineDetached(string root, string engine, string config)
    {
        try
        {
            string logPath = Path.Combine(root, "data", "engine.out.log");
            Directory.CreateDirectory(Path.GetDirectoryName(logPath));
            string inner = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + engine +
                           "\" -Root \"" + root + "\" -ConfigPath \"" + config + "\"";
            var psi = new ProcessStartInfo("cmd.exe", "/c chcp 65001 >nul & powershell.exe " + inner + " >> \"" + logPath + "\" 2>&1");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.WorkingDirectory = root;
            Process p = Process.Start(psi);
            Log("engine detached, cmd pid=" + (p == null ? 0 : p.Id));
        }
        catch (Exception ex) { Log("engine detach 失败: " + ex.Message); }
    }

    private static int RunPowerShell(string arguments, string root, bool capture)
    {
        // 统一走异步重定向: GUI 宿主下直接继承无效标准句柄会让 powershell 立刻退出,
        // 重定向后再边跑边把输出写进 engine.out.log 最稳。
        var psi = new ProcessStartInfo("powershell.exe", arguments);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = root;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;

        Log("spawn: powershell.exe " + arguments);
        using (Process p = Process.Start(psi))
        {
            Log("spawned pid=" + p.Id);
            p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data != null) AppendOut(root, e.Data);
            };
            p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data != null) AppendOut(root, e.Data);
            };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.WaitForExit();
            Log("child exit=" + p.ExitCode);
            return p.ExitCode;
        }
    }

    private static void AppendOut(string root, string line)
    {
        try
        {
            string dir = Path.Combine(root, "data");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "engine.out.log"), line + Environment.NewLine, new UTF8Encoding(true));
        }
        catch { }
    }

    private static string CapturePowerShell(string arguments, string root)
    {
        using (Process p = Process.Start(BuildPsi(arguments, root, true)))
        {
            string o = p.StandardOutput.ReadToEnd();
            string e = p.StandardError.ReadToEnd();
            p.WaitForExit();
            string all = (o + "\n" + e).Trim();
            return String.IsNullOrEmpty(all) ? "（没有输出）" : all;
        }
    }

    private static void StopEngine(string root)
    {
        string pidFile = Path.Combine(root, "data", "engine.pid");
        if (!File.Exists(pidFile)) return;
        string text = File.ReadAllText(pidFile).Trim();
        int pid;
        if (!Int32.TryParse(text, out pid)) return;
        try
        {
            Process p = Process.GetProcessById(pid);
            p.Kill();
        }
        catch { }
        try { File.Delete(pidFile); } catch { }
    }

    private static void ShowInfo(string text, string root, bool noUi)
    {
        if (noUi)
        {
            try
            {
                string dir = Path.Combine(root, "data");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "cli.out.log"),
                    "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + text + Environment.NewLine,
                    new UTF8Encoding(true));
            }
            catch { }
            return;
        }
        MessageBox.Show(text, ProductName + " " + AppVersion, MessageBoxButtons.OK, MessageBoxIcon.Information);
    }
}

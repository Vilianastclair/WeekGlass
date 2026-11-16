using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace WeekGlassSetup
{
    internal static class Copy
    {
        public static string Text(string english, string chinese)
        {
            return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? chinese : english;
        }
        public static string Version(Version version)
        {
            return version.ToString(3) + "+" + version.Revision.ToString(CultureInfo.InvariantCulture);
        }
    }

    internal sealed class Paths
    {
        private const uint OpenDirectory = 0x02000000;
        private const int FileNotFound = 2, PathNotFound = 3;
        public readonly string DefaultRuntime, StartShortcut, DesktopShortcut, Support, UninstallKey, SetupMutex, AppMutex;

        public Paths(string runtime, string start, string desktop, string support, string identity, string appMutex)
        {
            DefaultRuntime = Path.GetFullPath(runtime);
            StartShortcut = start;
            DesktopShortcut = desktop;
            Support = support;
            UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + identity;
            SetupMutex = @"Local\" + identity;
            AppMutex = appMutex;
        }

        public static Paths CurrentUser()
        {
            return new Paths(
                Path.Combine(KnownFolder(Environment.SpecialFolder.LocalApplicationData), "Programs", "WeekGlass"),
                Path.Combine(KnownFolder(Environment.SpecialFolder.Programs), "WeekGlass.lnk"),
                Path.Combine(KnownFolder(Environment.SpecialFolder.DesktopDirectory), "WeekGlass.lnk"),
                Path.Combine(KnownFolder(Environment.SpecialFolder.ApplicationData), "Viliana", "WeekGlass"),
                "Viliana.WeekGlass.Setup", @"Local\Viliana.WeekGlass.SingleInstance.v1");
        }

        private static string KnownFolder(Environment.SpecialFolder kind)
        {
            string path = Environment.GetFolderPath(kind, Environment.SpecialFolderOption.DoNotVerify);
            if (string.IsNullOrEmpty(path)) throw new IOException(Copy.Text("Windows did not provide a location for ", "Windows 未提供以下系统目录的位置：") + kind);
            return path;
        }

        public static string Application(string runtime) { return Path.Combine(runtime, "weekglass.exe"); }
        public static string Setup(string runtime) { return runtime + ".Setup"; }
        public static string Uninstaller(string runtime) { return Path.Combine(Setup(runtime), "Uninstall.exe"); }
        public static bool Equal(string a, string b) { return string.Equals(a, b, StringComparison.OrdinalIgnoreCase); }
        public static bool Inside(string path, string parent)
        {
            return Equal(path, parent) || path.StartsWith(parent.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
        }

        public string Normalize(string input)
        {
            string path = input.Trim().Replace('/', '\\').TrimEnd('\\');
            if (!Regex.IsMatch(path, @"^[A-Za-z]:\\.+")) throw BadDestination();
            foreach (string segment in path.Substring(3).Split('\\'))
            {
                if (segment.Length == 0 || segment.EndsWith(".") || segment.EndsWith(" ") ||
                    segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                    Regex.IsMatch(segment, @"^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(\.|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                    throw BadDestination();
            }
            path = Path.GetFullPath(path);
            string program = PhysicalPath(path);
            if (program.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) throw BadDestination();
            if (!Support.StartsWith(@"\\", StringComparison.Ordinal))
            {
                string data = PhysicalPath(Support);
                string setup = PhysicalPath(Setup(path));
                if (Inside(program, data) || Inside(data, program) || Inside(setup, data) || Inside(data, setup))
                    throw BadDestination();
            }
            return path;
        }

        public static string PhysicalPath(string path)
        {
            // Resolve the existing part so alternate drive letters and short names cannot
            // conceal overlap with a data directory or an existing installation.
            var missing = new Stack<string>();
            for (string parent = path; parent != null; parent = Path.GetDirectoryName(parent))
            {
                using (SafeFileHandle handle = CreateFile(parent, 0, FileShare.ReadWrite | FileShare.Delete,
                    IntPtr.Zero, FileMode.Open, OpenDirectory, IntPtr.Zero))
                {
                    if (handle.IsInvalid)
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error != FileNotFound && error != PathNotFound) throw PathError(parent, error);
                        missing.Push(Path.GetFileName(parent));
                        continue;
                    }

                    var resolved = new StringBuilder(512);
                    while (true)
                    {
                        uint length = GetFinalPathNameByHandle(handle, resolved, (uint)resolved.Capacity, 0);
                        if (length == 0) throw PathError(parent, Marshal.GetLastWin32Error());
                        if (length < resolved.Capacity) break;
                        resolved.EnsureCapacity((int)length + 1);
                    }
                    return resolved.ToString().TrimEnd('\\') + (missing.Count == 0 ? "" : "\\" + string.Join("\\", missing));
                }
            }
            throw BadDestination();
        }

        private static IOException PathError(string path, int error)
        {
            return new IOException(Copy.Text("Windows could not verify this folder: ", "Windows 无法确认此文件夹：") + path, new Win32Exception(error));
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, FileShare share, IntPtr security,
            FileMode creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle directory, StringBuilder path, uint capacity, uint flags);

        private static IOException BadDestination()
        {
            return new IOException(Copy.Text("Enter a dedicated folder on a local drive, such as D:\\Apps\\WeekGlass.", "请输入本地磁盘上的独立文件夹，例如 D:\\Apps\\WeekGlass。"));
        }
    }

    internal sealed class Exclusive : IDisposable
    {
        private readonly Mutex mutex;
        public Exclusive(string name, string busy)
        {
            mutex = new Mutex(false, name);
            try { if (mutex.WaitOne(0)) return; }
            catch (AbandonedMutexException) { return; }
            mutex.Dispose();
            throw new InvalidOperationException(busy);
        }
        public void Dispose() { mutex.ReleaseMutex(); mutex.Dispose(); }
    }

    internal sealed class Installation
    {
        private readonly Paths paths;
        private readonly Version version;
        public Installation(Paths paths, Version version) { this.paths = paths; this.version = version; }

        private Exclusive SetupLock()
        {
            return new Exclusive(paths.SetupMutex, Copy.Text("Another WeekGlass installer is running. Close it and try again.", "另一个 WeekGlass 安装程序正在运行。关闭后重试。"));
        }
        private Exclusive AppLock()
        {
            return new Exclusive(paths.AppMutex, Copy.Text("Exit WeekGlass from its notification-area icon, then try again.", "请在系统托盘中完全退出 WeekGlass，然后重试。"));
        }

        public string RegisteredRuntime()
        {
            using (RegistryKey entry = Registry.CurrentUser.OpenSubKey(paths.UninstallKey))
            {
                if (entry == null) return null;
                string location = entry.GetValue("InstallLocation") as string;
                if (string.IsNullOrWhiteSpace(location)) throw InvalidRegistration();
                string runtime = paths.Normalize(location);
                if (!Paths.Equal(entry.GetValue("UninstallString") as string, "\"" + Paths.Uninstaller(runtime) + "\""))
                    throw InvalidRegistration();
                return runtime;
            }
        }

        private static IOException InvalidRegistration()
        {
            return new IOException(Copy.Text("The existing WeekGlass installation could not be verified. Check it under Installed apps.", "无法确认现有的 WeekGlass 安装。请在 Windows 的「已安装的应用」中查看。"));
        }

        private static void CheckProgramPaths(string runtime)
        {
            foreach (string target in new[] { runtime, Paths.Setup(runtime) })
                for (string folder = target; folder != null; folder = Path.GetDirectoryName(folder))
                {
                    FileAttributes attr;
                    try { attr = File.GetAttributes(folder); }
                    catch (FileNotFoundException) { continue; }
                    catch (DirectoryNotFoundException) { continue; }
                    if ((attr & FileAttributes.ReparsePoint) != 0 || (attr & FileAttributes.Directory) == 0)
                        throw new IOException(Copy.Text("Choose a folder that is not redirected or occupied by a file: ", "请选择未被重定向且不与文件重名的文件夹：") + folder);
                }
        }

        private static Version ReadVersion(string filename)
        {
            if (!File.Exists(filename)) return null;
            FileVersionInfo info = FileVersionInfo.GetVersionInfo(filename);
            if (info.ProductName != "WeekGlass") return null;
            return new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart, info.FilePrivatePart);
        }

        private static Version CheckRegistered(string runtime)
        {
            CheckProgramPaths(runtime);
            string setup = Paths.Setup(runtime);
            string uninstall = Paths.Uninstaller(runtime);
            if (Directory.Exists(setup))
            {
                string[] entries = Directory.GetFileSystemEntries(setup);
                if (entries.Length != 1 || !Paths.Equal(entries[0], uninstall) || ReadVersion(uninstall) == null)
                    throw InvalidRegistration();
            }
            if (!Directory.Exists(runtime)) return null;
            Version current = ReadVersion(Paths.Application(runtime));
            if (current == null) throw InvalidRegistration();
            return current;
        }

        private string CheckDestination(string runtime)
        {
            string current = RegisteredRuntime();
            CheckProgramPaths(runtime);
            if (current != null)
            {
                Version installed = CheckRegistered(current);
                if (installed != null && installed > version)
                    throw new InvalidOperationException(Copy.Text("A newer version of WeekGlass is already installed.", "此电脑已安装较新的 WeekGlass 版本。"));
            }
            if (!Paths.Equal(current, runtime))
            {
                if (current != null)
                {
                    string[] nextPaths = { Paths.PhysicalPath(runtime), Paths.PhysicalPath(Paths.Setup(runtime)) };
                    string[] previousPaths = { Paths.PhysicalPath(current), Paths.PhysicalPath(Paths.Setup(current)) };
                    foreach (string next in nextPaths)
                        foreach (string previous in previousPaths)
                            if (Paths.Inside(next, previous) || Paths.Inside(previous, next))
                                throw new IOException(Copy.Text("Choose a location outside the current installation.", "请选择与现有安装互不包含的位置。"));
                }
                if (Directory.Exists(Paths.Setup(runtime)) ||
                    (Directory.Exists(runtime) && Directory.GetFileSystemEntries(runtime).Length != 0))
                    throw new IOException(Copy.Text("Choose a new or empty installation folder: ", "请选择新建或空的安装文件夹：") + runtime);
            }
            return current;
        }

        private static string Scratch(string runtime)
        {
            return Path.Combine(Path.GetDirectoryName(runtime), ".weekglass-setup-" + Guid.NewGuid().ToString("N"));
        }

        public string Install(string destination, bool desktop, Stream payload, Stream uninstaller)
        {
            string runtime = paths.Normalize(destination);
            using (SetupLock())
            {
                string previous = CheckDestination(runtime);
                string stage = Scratch(runtime);
                string old = previous == null || Paths.Equal(previous, runtime) ? stage : Scratch(previous);
                string nextRuntime = Path.Combine(stage, "program");
                string nextSetup = Path.Combine(stage, "setup");
                bool recovered = true;
                try
                {
                    Directory.CreateDirectory(nextSetup);
                    using (var zip = new ZipArchive(payload, ZipArchiveMode.Read, true)) zip.ExtractToDirectory(nextRuntime);
                    if (ReadVersion(Paths.Application(nextRuntime)) != version || !File.Exists(Path.Combine(nextRuntime, "weekglass_updater.exe")))
                        throw new InvalidDataException(Copy.Text("The installer payload is incomplete or has the wrong version.", "安装包缺少文件，或应用版本不符。"));
                    using (var output = File.Create(Path.Combine(nextSetup, "Uninstall.exe"))) uninstaller.CopyTo(output);
                    using (AppLock())
                    {
                        CheckDestination(runtime);
                        try
                        {
                            Transact(undo => {
                                if (previous != null)
                                {
                                    Directory.CreateDirectory(old);
                                    MoveAside(previous, Path.Combine(old, "old-program"), undo);
                                    MoveAside(Paths.Setup(previous), Path.Combine(old, "old-setup"), undo);
                                }
                                MoveAside(runtime, Path.Combine(stage, "empty-destination"), undo);
                                PublishDirectory(nextRuntime, runtime, undo);
                                PublishDirectory(nextSetup, Paths.Setup(runtime), undo);
                                UpdateShortcut(paths.StartShortcut, runtime, previous, true, Path.Combine(stage, "start.lnk"), undo);
                                UpdateShortcut(paths.DesktopShortcut, runtime, previous, desktop, Path.Combine(stage, "desktop.lnk"), undo);
                                Register(runtime, undo);
                            });
                        }
                        catch (AggregateException) { recovered = false; throw RecoveryError(stage, old); }
                    }
                    return runtime;
                }
                finally
                {
                    if (recovered)
                    {
                        Clean(stage);
                        if (!Paths.Equal(old, stage)) Clean(old);
                    }
                }
            }
        }

        private static void Transact(Action<Stack<Action>> change)
        {
            var undo = new Stack<Action>();
            try { change(undo); }
            catch (Exception failure)
            {
                var errors = new List<Exception> { failure };
                while (undo.Count != 0)
                {
                    try { undo.Pop()(); }
                    catch (Exception restoreError) { errors.Add(restoreError); }
                }
                if (errors.Count == 1) throw;
                throw new AggregateException(errors);
            }
        }

        private static IOException RecoveryError(string first, string second)
        {
            return new IOException(Copy.Text("Setup could not roll back completely. Recovery files: ", "未能完全回退。恢复文件位于：") + first +
                (Paths.Equal(first, second) ? "" : Environment.NewLine + second));
        }

        private static void Clean(string stage)
        {
            try
            {
                if (Directory.Exists(stage)) Directory.Delete(stage, true);
            }
            catch (IOException error) { Trace.TraceWarning(error.Message); }
            catch (UnauthorizedAccessException error) { Trace.TraceWarning(error.Message); }
        }

        private static void MoveAside(string source, string backup, Stack<Action> undo)
        {
            if (!Directory.Exists(source)) return;
            Directory.Move(source, backup);
            undo.Push(() => Directory.Move(backup, source));
        }

        private static void PublishDirectory(string from, string to, Stack<Action> undo)
        {
            Directory.Move(from, to);
            undo.Push(() => Directory.Move(to, from));
        }

        private static void UpdateShortcut(string filename, string runtime, string previous, bool create, string backup, Stack<Action> undo)
        {
            object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true));
            try
            {
                if (File.Exists(filename))
                {
                    // Copy before reading through the shell; some shell implementations return
                    // an empty target instead of reporting that the original link is locked.
                    File.Copy(filename, backup);
                    dynamic oldLink = ((dynamic)shell).CreateShortcut(backup);
                    try
                    {
                        if (!Paths.Equal((string)oldLink.TargetPath, Paths.Application(runtime)) &&
                            (previous == null || !Paths.Equal((string)oldLink.TargetPath, Paths.Application(previous))))
                        {
                            if (!create) return;
                            throw new IOException(Copy.Text("A different WeekGlass shortcut already uses this name: ", "已有不同位置的同名 WeekGlass 快捷方式：") + filename);
                        }
                    }
                    finally { Marshal.FinalReleaseComObject(oldLink); }
                    File.Delete(filename);
                    undo.Push(() => File.Copy(backup, filename, true));
                }
                else if (create) undo.Push(() => File.Delete(filename));

                if (!create) return;
                Directory.CreateDirectory(Path.GetDirectoryName(filename));
                dynamic link = ((dynamic)shell).CreateShortcut(filename);
                try
                {
                    link.TargetPath = Paths.Application(runtime);
                    link.WorkingDirectory = runtime;
                    link.IconLocation = Paths.Application(runtime) + ",0";
                    link.Description = "WeekGlass";
                    link.Save();
                }
                finally { Marshal.FinalReleaseComObject(link); }
            }
            finally { Marshal.FinalReleaseComObject(shell); }
        }

        private void Register(string runtime, Stack<Action> undo)
        {
            var values = new Dictionary<string, object> {
                { "DisplayName", "WeekGlass" }, { "DisplayVersion", Copy.Version(version) },
                { "Publisher", "Viliana" }, { "InstallLocation", runtime },
                { "DisplayIcon", Paths.Application(runtime) }, { "URLInfoAbout", "https://github.com/Vilianastclair/WeekGlass" },
                { "UninstallString", "\"" + Paths.Uninstaller(runtime) + "\"" },
                { "NoModify", 1 }, { "NoRepair", 1 },
            };
            using (RegistryKey existing = Registry.CurrentUser.OpenSubKey(paths.UninstallKey))
            {
                if (existing == null) undo.Push(() => Registry.CurrentUser.DeleteSubKeyTree(paths.UninstallKey, false));
            }
            using (RegistryKey entry = Registry.CurrentUser.CreateSubKey(paths.UninstallKey))
            {
                foreach (var row in values)
                {
                    string name = row.Key;
                    object old = entry.GetValue(name);
                    RegistryValueKind kind = old == null ? RegistryValueKind.Unknown : entry.GetValueKind(name);
                    undo.Push(() => {
                        using (RegistryKey restore = Registry.CurrentUser.OpenSubKey(paths.UninstallKey, true))
                        {
                            if (old == null) restore.DeleteValue(name, false);
                            else restore.SetValue(name, old, kind);
                        }
                    });
                    entry.SetValue(name, row.Value);
                }
            }
        }

        public void Uninstall(string runtime)
        {
            using (SetupLock())
            using (AppLock())
            {
                if (!Paths.Equal(runtime, RegisteredRuntime())) throw InvalidRegistration();
                CheckRegistered(runtime);
                string stage = Scratch(runtime);
                bool recovered = true;
                try
                {
                    Directory.CreateDirectory(stage);
                    Transact(undo => {
                        UpdateShortcut(paths.StartShortcut, runtime, null, false, Path.Combine(stage, "start.lnk"), undo);
                        UpdateShortcut(paths.DesktopShortcut, runtime, null, false, Path.Combine(stage, "desktop.lnk"), undo);
                        // Only the registered program and its uninstaller are moved. Calendar and settings are elsewhere.
                        MoveAside(runtime, Path.Combine(stage, "old-program"), undo);
                        MoveAside(Paths.Setup(runtime), Path.Combine(stage, "old-setup"), undo);
                        Registry.CurrentUser.DeleteSubKeyTree(paths.UninstallKey, false);
                    });
                }
                catch (AggregateException) { recovered = false; throw RecoveryError(stage, stage); }
                finally { if (recovered) Clean(stage); }
            }
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try
            {
                var paths = Paths.CurrentUser();
                Assembly assembly = Assembly.GetExecutingAssembly();
                Version version = assembly.GetName().Version;
                var installation = new Installation(paths, version);
#if UNINSTALLER
                RunUninstaller(args, assembly.Location, version, installation);
#else
                if (Environment.OSVersion.Version < new Version(10, 0, 17763))
                {
                    MessageBox.Show(Copy.Text("WeekGlass requires Windows 10 version 1809 or later.", "WeekGlass 需要 Windows 10 1809 或更高版本。"), "WeekGlass");
                    return;
                }
                string current = installation.RegisteredRuntime();
                Application.Run(new SetupWindow(false, version, current ?? paths.DefaultRuntime, current, (destination, desktop) => {
                    using (Stream payload = assembly.GetManifestResourceStream("WeekGlass.Payload"))
                    using (Stream uninstaller = assembly.GetManifestResourceStream("WeekGlass.Uninstaller"))
                        return installation.Install(destination, desktop, payload, uninstaller);
                }));
#endif
            }
            catch (Exception error) { MessageBox.Show(error.Message, "WeekGlass", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        }

#if UNINSTALLER
        private static void RunUninstaller(string[] args, string location, Version version, Installation installation)
        {
            string runtime = installation.RegisteredRuntime();
            if (args.Length == 0)
            {
                if (runtime == null || !Paths.Equal(location, Paths.Uninstaller(runtime)))
                    throw new InvalidOperationException(Copy.Text("Open the uninstaller from Windows Installed apps.", "请从 Windows 的「已安装的应用」打开卸载程序。"));
                string copy = Path.Combine(Path.GetTempPath(), "WeekGlass-Uninstall-" + Guid.NewGuid().ToString("N") + ".exe");
                File.Copy(location, copy);
                try
                {
                    using (Process self = Process.GetCurrentProcess())
                    using (Process child = Process.Start(new ProcessStartInfo(copy,
                        self.Id.ToString(CultureInfo.InvariantCulture) + " \"" + runtime + "\"") { UseShellExecute = false })) { }
                }
                catch { File.Delete(copy); throw; }
                return;
            }
            int parentId;
            if (args.Length != 2 || !int.TryParse(args[0], out parentId) ||
                !Paths.Equal(Path.GetDirectoryName(location), Path.GetTempPath().TrimEnd('\\')) ||
                !Regex.IsMatch(Path.GetFileName(location), @"^WeekGlass-Uninstall-[0-9a-f]{32}\.exe$"))
                return;

            try
            {
                Process parent = null;
                try { parent = Process.GetProcessById(parentId); }
                catch (ArgumentException) { /* The original uninstaller already exited. */ }
                using (parent) { if (parent != null && !parent.WaitForExit(5000)) return; }
                if (!Paths.Equal(runtime, args[1])) throw new InvalidOperationException(Copy.Text("The installation changed. Open its current uninstaller.", "安装位置已变化，请重新打开卸载程序。"));
                Application.Run(new SetupWindow(true, version, runtime, runtime, (destination, desktop) => {
                    installation.Uninstall(runtime);
                    return null;
                }));
            }
            finally { CleanUninstallerCopy(location); }
        }

        private static void CleanUninstallerCopy(string location)
        {
            // Windows locks the temporary executable until this process exits.
            string script;
            using (Process self = Process.GetCurrentProcess())
                script = "$p=Get-Process -Id " + self.Id.ToString(CultureInfo.InvariantCulture) +
                    " -ErrorAction SilentlyContinue; if ($p) { $p.WaitForExit() }; Remove-Item -LiteralPath '" +
                    location.Replace("'", "''") + "' -ErrorAction SilentlyContinue";
            var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
                "-NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script))) {
                UseShellExecute = false, CreateNoWindow = true
            };
            try { using (Process cleanup = Process.Start(start)) { } }
            catch (System.ComponentModel.Win32Exception error) { Trace.TraceWarning(error.Message); }
        }
#endif
    }
}

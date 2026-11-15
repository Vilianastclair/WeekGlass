using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace WeekGlassSetup
{
    internal static class Copy
    {
        private static readonly bool Chinese = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh";
        public static string Text(string english, string chinese) { return Chinese ? chinese : english; }
        public static string Version(Version version)
        {
            return version.ToString(3) + "+" + version.Revision.ToString(CultureInfo.InvariantCulture);
        }
    }

    internal sealed class Paths
    {
        public readonly string Runtime, Setup, Shortcut, UninstallKey, SetupMutex, AppMutex;
        public string Application { get { return Path.Combine(Runtime, "weekglass.exe"); } }
        public string Uninstaller { get { return Path.Combine(Setup, "Uninstall.exe"); } }
        public string Parent { get { return Path.GetDirectoryName(Runtime); } }

        public Paths(string runtime, string shortcut, string identity, string appMutex)
        {
            Runtime = Path.GetFullPath(runtime);
            Setup = Runtime + ".Setup";
            Shortcut = shortcut;
            UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + identity;
            SetupMutex = @"Local\" + identity;
            AppMutex = appMutex;
        }

        public static Paths CurrentUser()
        {
            return new Paths(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "WeekGlass"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "WeekGlass.lnk"),
                "Viliana.WeekGlass.Setup", @"Local\Viliana.WeekGlass.SingleInstance.v1");
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

        private void CheckProgramPaths()
        {
            foreach (string folder in new[] { paths.Parent, paths.Runtime, paths.Setup })
            {
                if (Directory.Exists(folder) && (File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException(Copy.Text("The installation folder is redirected: ", "安装目录是重定向位置：") + folder);
            }
        }

        private static Version ReadVersion(string directory)
        {
            if (!Directory.Exists(directory)) return null;
            string filename = Path.Combine(directory, "weekglass.exe");
            if (File.Exists(filename))
            {
                FileVersionInfo info = FileVersionInfo.GetVersionInfo(filename);
                if (info.ProductName == "WeekGlass")
                    return new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart, info.FilePrivatePart);
            }
            throw new IOException(Copy.Text("The folder does not contain a recognized WeekGlass installation: ", "无法确认此目录属于 WeekGlass：") + directory);
        }

        private void CheckVersion()
        {
            Version current = ReadVersion(paths.Runtime);
            if (current != null && current > version)
                throw new InvalidOperationException(Copy.Text("A newer version of WeekGlass is already installed.", "此电脑已安装较新的 WeekGlass 版本。"));
        }

        public void Install(Stream payload, Stream uninstaller)
        {
            using (SetupLock())
            {
                CheckProgramPaths();
                CheckVersion();

                string scratch = Path.Combine(paths.Parent, ".weekglass-setup-" + Guid.NewGuid().ToString("N"));
                string nextRuntime = Path.Combine(scratch, "program");
                string nextSetup = Path.Combine(scratch, "setup");
                string nextShortcut = Path.Combine(scratch, "WeekGlass.lnk");
                var undo = new Stack<Action>();
                bool recovered = true;
                try
                {
                    Directory.CreateDirectory(nextSetup);
                    using (var zip = new ZipArchive(payload, ZipArchiveMode.Read, true)) zip.ExtractToDirectory(nextRuntime);
                    if (ReadVersion(nextRuntime) != version || !File.Exists(Path.Combine(nextRuntime, "weekglass_updater.exe")))
                        throw new InvalidDataException(Copy.Text("The installer payload is incomplete or has the wrong version.", "安装包缺少文件，或应用版本不符。"));
                    using (var output = File.Create(Path.Combine(nextSetup, "Uninstall.exe"))) uninstaller.CopyTo(output);
                    CreateShortcut(nextShortcut, paths.Application, paths.Runtime);
                    using (AppLock())
                    {
                        CheckProgramPaths();
                        CheckVersion();
                        try
                        {
                            Swap(nextRuntime, paths.Runtime, Path.Combine(scratch, "old-program"), undo);
                            Swap(nextSetup, paths.Setup, Path.Combine(scratch, "old-setup"), undo);
                            Directory.CreateDirectory(Path.GetDirectoryName(paths.Shortcut));
                            string oldShortcut = Path.Combine(scratch, "old-shortcut.lnk");
                            if (File.Exists(paths.Shortcut))
                            {
                                File.Copy(paths.Shortcut, oldShortcut);
                                undo.Push(() => File.Copy(oldShortcut, paths.Shortcut, true));
                            }
                            else undo.Push(() => File.Delete(paths.Shortcut));
                            File.Copy(nextShortcut, paths.Shortcut, true);
                            Register(undo);
                        }
                        catch (Exception failure)
                        {
                            var errors = new List<Exception> { failure };
                            while (undo.Count != 0)
                            {
                                try { undo.Pop()(); }
                                catch (Exception restoreError) { errors.Add(restoreError); }
                            }
                            if (errors.Count == 1) throw;
                            recovered = false;
                            throw new AggregateException(Copy.Text("Setup could not roll back. The recovery files are at: ", "安装未能完全回退，恢复文件位于：") + scratch, errors);
                        }
                    }
                }
                finally
                {
                    // This is a generated sibling containing installer scratch and previous program files only.
                    if (recovered && Directory.Exists(scratch)) Directory.Delete(scratch, true);
                }
            }
        }

        private static void Swap(string source, string destination, string previous, Stack<Action> undo)
        {
            if (Directory.Exists(destination))
            {
                Directory.Move(destination, previous);
                undo.Push(() => Directory.Move(previous, destination));
            }
            Directory.Move(source, destination);
            undo.Push(() => Directory.Move(destination, source));
        }

        private static void CreateShortcut(string shortcutFile, string target, string workingDirectory)
        {
            object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true));
            try
            {
                dynamic shortcut = ((dynamic)shell).CreateShortcut(shortcutFile);
                try
                {
                    shortcut.TargetPath = target;
                    shortcut.WorkingDirectory = workingDirectory;
                    shortcut.Description = "WeekGlass";
                    shortcut.Save();
                }
                finally { Marshal.FinalReleaseComObject(shortcut); }
            }
            finally { Marshal.FinalReleaseComObject(shell); }
        }

        private void Register(Stack<Action> undo)
        {
            var values = new Dictionary<string, object> {
                { "DisplayName", "WeekGlass" }, { "DisplayVersion", Copy.Version(version) },
                { "Publisher", "Viliana" }, { "InstallLocation", paths.Runtime },
                { "DisplayIcon", paths.Application }, { "URLInfoAbout", "https://github.com/Vilianastclair/WeekGlass" },
                { "UninstallString", "\"" + paths.Uninstaller + "\"" },
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
                    object previous = entry.GetValue(name);
                    undo.Push(() => {
                        using (RegistryKey restore = Registry.CurrentUser.OpenSubKey(paths.UninstallKey, true))
                        {
                            if (previous == null) restore.DeleteValue(name, false);
                            else restore.SetValue(name, previous);
                        }
                    });
                    entry.SetValue(name, row.Value);
                }
            }
        }

        public void Uninstall()
        {
            using (SetupLock())
            using (AppLock())
            {
                CheckProgramPaths();
                // Uninstall owns the dedicated runtime, including assets added by in-app updates.
                // User calendars and preferences use the separate application-support directory.
                if (ReadVersion(paths.Runtime) != null) Directory.Delete(paths.Runtime, true);
                File.Delete(paths.Shortcut);
                Registry.CurrentUser.DeleteSubKeyTree(paths.UninstallKey, false);
                File.Delete(paths.Uninstaller);
                if (Directory.Exists(paths.Setup) && Directory.GetFileSystemEntries(paths.Setup).Length == 0)
                    Directory.Delete(paths.Setup);
            }
        }
    }

    internal sealed class SetupWindow : Form
    {
        private readonly Action operation;
        private readonly bool uninstall;
        private readonly Label body;
        private readonly Button primary, cancel;
        private readonly ProgressBar progress;
        private bool busy, complete;

        public SetupWindow(bool uninstall, Version version, Action operation)
        {
            this.uninstall = uninstall;
            this.operation = operation;
            Text = uninstall ? Copy.Text("Uninstall WeekGlass", "卸载 WeekGlass") : Copy.Text("WeekGlass Setup", "安装 WeekGlass");
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            AutoScaleDimensions = new SizeF(96, 96);
            AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(478, 248);
            BackColor = Color.White;
            Font = new Font("Segoe UI", 10);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterScreen;
            MinimizeBox = false;
            MaximizeBox = false;

            var mark = new PictureBox { Location = new Point(27, 24), Size = new Size(51, 51), SizeMode = PictureBoxSizeMode.CenterImage, Image = new Icon(Icon, 48, 48).ToBitmap() };
            var title = new Label { Location = new Point(91, 19), Size = new Size(350, 39), Text = "WeekGlass", Font = new Font(Font.FontFamily, 22, FontStyle.Bold), ForeColor = Color.FromArgb(28, 39, 61) };
            var subtitle = new Label { Location = new Point(94, 62), Size = new Size(345, 23), Text = uninstall ? Copy.Text("UNINSTALL", "卸载") : Copy.Text("WINDOWS x64  ·  ", "Windows x64 安装包  ·  ") + Copy.Version(version), ForeColor = Color.FromArgb(75, 92, 120) };
            body = new Label { Location = new Point(28, 103), Size = new Size(420, 61), ForeColor = Color.FromArgb(33, 43, 64), Text = uninstall
                ? Copy.Text("Remove WeekGlass from this Windows account. Your calendar and settings will be kept.", "从此 Windows 账号卸载 WeekGlass，保留日程和偏好。")
                : Copy.Text("Install for this Windows account.\r\nOpen WeekGlass from the Start menu after setup.", "为当前 Windows 账号安装。\r\n安装后，从「开始」菜单打开 WeekGlass。") };
            progress = new ProgressBar { Location = new Point(28, 173), Size = new Size(420, 8), Style = ProgressBarStyle.Marquee, Visible = false };
            var rule = new Panel { Location = new Point(0, 190), Size = new Size(478, 1), BackColor = Color.FromArgb(226, 231, 239) };
            cancel = new Button { Location = new Point(225, 203), Size = new Size(103, 31), Text = Copy.Text("Cancel", "取消"), DialogResult = DialogResult.Cancel };
            primary = new Button { Location = new Point(337, 203), Size = new Size(112, 31), Text = uninstall ? Copy.Text("Uninstall", "卸载") : Copy.Text("Install", "安装"), BackColor = Color.FromArgb(45, 71, 122), ForeColor = Color.White, FlatStyle = FlatStyle.Flat };
            primary.FlatAppearance.BorderSize = 0;
            primary.FlatAppearance.MouseOverBackColor = Color.FromArgb(65, 93, 147);
            primary.Click += RunOperation;
            cancel.Click += (sender, args) => Close();
            Controls.AddRange(new Control[] { mark, title, subtitle, body, progress, rule, cancel, primary });
            AcceptButton = primary;
            CancelButton = cancel;
        }

        private async void RunOperation(object sender, EventArgs args)
        {
            if (complete) { Close(); return; }
            busy = true;
            primary.Enabled = cancel.Enabled = false;
            body.Text = uninstall ? Copy.Text("Uninstalling WeekGlass…", "正在卸载 WeekGlass…") : Copy.Text("Installing WeekGlass…", "正在安装 WeekGlass…");
            progress.Visible = true;
            try
            {
                await Task.Run(operation);
                complete = true;
                body.Text = uninstall ? Copy.Text("WeekGlass was removed. Your calendar and settings are still on this PC.", "已卸载 WeekGlass，日程和偏好仍留在此电脑上。")
                    : Copy.Text("WeekGlass is ready. You can now open it from the Start menu.", "安装完成。现在可从开始菜单打开 WeekGlass。");
                primary.Text = Copy.Text("Finish", "完成");
                cancel.Visible = false;
            }
            catch (Exception error)
            {
                body.Text = error.Message;
                primary.Text = Copy.Text("Try again", "重试");
            }
            finally
            {
                progress.Visible = busy = false;
                primary.Enabled = cancel.Enabled = true;
                primary.Focus();
            }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (busy) e.Cancel = true;
            base.OnFormClosing(e);
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            var paths = Paths.CurrentUser();
            Assembly assembly = Assembly.GetExecutingAssembly();
            Version version = assembly.GetName().Version;
            var installation = new Installation(paths, version);
#if UNINSTALLER
            // Run outside the install tree so Windows can delete the installed uninstaller.
            if (string.Equals(assembly.Location, paths.Uninstaller, StringComparison.OrdinalIgnoreCase))
            {
                string copy = Path.Combine(Path.GetTempPath(), "WeekGlass-Uninstall-" + Guid.NewGuid().ToString("N") + ".exe");
                File.Copy(assembly.Location, copy);
                using (Process self = Process.GetCurrentProcess())
                using (Process child = Process.Start(new ProcessStartInfo(copy, self.Id.ToString(CultureInfo.InvariantCulture)) { UseShellExecute = false })) { }
                return;
            }
            int parentId;
            if (args.Length == 1 && int.TryParse(args[0], out parentId))
            {
                Process parent = null;
                try { parent = Process.GetProcessById(parentId); }
                catch (ArgumentException) { /* The original uninstaller already exited. */ }
                using (parent) { if (parent != null && !parent.WaitForExit(5000)) return; }
            }
            const bool uninstall = true;
            Action operation = installation.Uninstall;
#else
            const bool uninstall = false;
            Action operation = () => {
                using (Stream payload = assembly.GetManifestResourceStream("WeekGlass.Payload"))
                using (Stream uninstaller = assembly.GetManifestResourceStream("WeekGlass.Uninstaller"))
                    installation.Install(payload, uninstaller);
            };
            if (Environment.OSVersion.Version < new Version(10, 0, 17763))
            {
                MessageBox.Show(Copy.Text("WeekGlass requires Windows 10 version 1809 or later.", "WeekGlass 需要 Windows 10 1809 或更高版本。"), "WeekGlass");
                return;
            }
#endif
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SetupWindow(uninstall, version, operation));
        }
    }
}

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
using System.Windows.Forms;
using Microsoft.Win32;

namespace WeekGlassSetup
{
    internal static class InstallerSmoke
    {
        private static void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }

        private static string Install(Assembly setup, Installation installation, string destination, bool desktop = true)
        {
            using (Stream payload = setup.GetManifestResourceStream("WeekGlass.Payload"))
            using (Stream uninstaller = setup.GetManifestResourceStream("WeekGlass.Uninstaller"))
                return installation.Install(destination, desktop, payload, uninstaller);
        }

        private static void VerifyShortcut(string filename, string runtime)
        {
            Require(File.Exists(filename), "Shortcut missing: " + filename);
            object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true));
            try
            {
                dynamic link = ((dynamic)shell).CreateShortcut(filename);
                try
                {
                    Require(link.TargetPath == Paths.Application(runtime), "Shortcut target mismatch: " + filename);
                    Require(link.WorkingDirectory == runtime, "Shortcut working directory mismatch: " + filename);
                    Require(((string)link.IconLocation).StartsWith(Paths.Application(runtime)), "Shortcut icon mismatch: " + filename);
                }
                finally { Marshal.FinalReleaseComObject(link); }
            }
            finally { Marshal.FinalReleaseComObject(shell); }
        }

        private static void VerifyRegistration(Paths paths, string runtime, Version version)
        {
            Require(File.Exists(Paths.Uninstaller(runtime)), "Uninstaller missing at selected location");
            using (var entry = Registry.CurrentUser.OpenSubKey(paths.UninstallKey))
            {
                Require(entry != null && (string)entry.GetValue("UninstallString") == "\"" + Paths.Uninstaller(runtime) + "\"", "Installed Apps entry missing");
                Require((string)entry.GetValue("DisplayVersion") == Copy.Version(version), "Installed Apps has the wrong version");
                Require((string)entry.GetValue("InstallLocation") == runtime, "Installed Apps has the wrong location");
                Require((string)entry.GetValue("DisplayIcon") == Paths.Application(runtime), "Installed Apps icon has the wrong location");
            }
        }

        private static void PressDialogKey(SetupWindow window, Keys key)
        {
            var process = typeof(Form).GetMethod("ProcessDialogKey", BindingFlags.Instance | BindingFlags.NonPublic);
            Require((bool)process.Invoke(window, new object[] { key }), "Setup did not handle the keyboard action " + key);
        }
        private static void Render(SetupWindow window, string output)
        {
            if (!window.Visible)
            {
                window.StartPosition = FormStartPosition.Manual;
                window.Location = new Point(-10000, -10000);
                window.ShowInTaskbar = false;
                window.Show();
                Application.DoEvents();
            }
            using (var screenshot = new Bitmap(window.Width, window.Height))
            {
                Require(window.Handle != IntPtr.Zero, "Setup window handle missing");
                foreach (Control child in window.Controls)
                    Require(child.Handle != IntPtr.Zero, "Setup child control handle missing");
                window.DrawToBitmap(screenshot, new Rectangle(0, 0, window.Width, window.Height));
                screenshot.Save(output);
            }
        }

        private static void WaitForButton(SetupWindow window, string label)
        {
            var timer = Stopwatch.StartNew();
            while ((!((Button)window.AcceptButton).Enabled || ((Button)window.AcceptButton).Text != label) && timer.ElapsedMilliseconds < 15000)
            {
                Application.DoEvents();
                Thread.Sleep(10);
            }
            Require(((Button)window.AcceptButton).Enabled && ((Button)window.AcceptButton).Text == label, "Setup did not reach " + label);
        }

        private static void CollectFonts(Control control, Dictionary<Control, Font> fonts)
        {
            fonts.Add(control, control.Font);
            foreach (Control child in control.Controls) CollectFonts(child, fonts);
        }

        private static void VerifyWordmark(SetupWindow window)
        {
            var mark = (PictureBox)window.Controls.Find("brandMark", true)[0];
            Require(mark.Image.Width == 512 && mark.Image.Height == 512, "Header did not load the high-resolution brand mark");
            Control title = window.Controls.Find("wordmark", true)[0];
            Control subtitle = window.Controls.Find("tagline", true)[0];
            var preferred = title.GetPreferredSize(Size.Empty);
            Require(title.Height >= preferred.Height && title.Width >= preferred.Width && title.Bottom <= subtitle.Top,
                "Brand wordmark is clipped or overlaps its subtitle");
        }

        private static void VerifyScaledWindow(Version version, string output, string path, Func<string, bool, string> install)
        {
            using (var window = new SetupWindow(false, version, path, null, install))
            {
                // Simulate 144 DPI on the 96-DPI runner without changing the user display settings.
                const float scale = 1.5f;
                var initialFonts = new Dictionary<Control, Font>();
                CollectFonts(window, initialFonts);
                window.Scale(new SizeF(scale, scale));
                var scaledFonts = new List<Font>();
                try
                {
                    foreach (var entry in initialFonts)
                    {
                        var font = new Font(entry.Value.FontFamily, entry.Value.SizeInPoints * scale, entry.Value.Style);
                        scaledFonts.Add(font);
                        entry.Key.Font = font;
                    }
                    Render(window, Path.Combine(output, "setup-window-150pct-simulated.png"));
                    VerifyWordmark(window);
                }
                finally
                {
                    window.Close();
                    foreach (Font font in scaledFonts) font.Dispose();
                }
            }
        }

        private static void VerifyWindows(Version version, string output, string runtime)
        {
            SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
            int calls = 0;
            string selected = Path.Combine(Path.GetDirectoryName(runtime), "Package Trial");
            Func<string, bool, string> install = (target, shortcut) => {
                Require(target == selected && shortcut, "Install did not receive the chosen full path and desktop option");
                if (Interlocked.Increment(ref calls) == 1) throw new IOException("请选择新建或空的安装文件夹。");
                return selected;
            };
            string defaultPath = Paths.CurrentUser().DefaultRuntime;
            using (var window = new SetupWindow(false, version, defaultPath, null, install))
            {
                Render(window, Path.Combine(output, "setup-window.png"));
                VerifyWordmark(window);
                var target = (TextBox)window.Controls.Find("destination", true)[0];
                var option = (CheckBox)window.Controls.Find("desktopShortcut", true)[0];
                Require(option.Checked && !target.ReadOnly, "Installation folder or required initial desktop option unavailable");
                target.Text = selected;
                PressDialogKey(window, Keys.Enter);
                WaitForButton(window, "返回");
                Render(window, Path.Combine(output, "setup-error-window.png"));
                PressDialogKey(window, Keys.Enter);
                Require(target.Text == selected && option.Checked, "Going back discarded the selected options");
                PressDialogKey(window, Keys.Enter);
                WaitForButton(window, "打开 WeekGlass");
                Render(window, Path.Combine(output, "setup-complete-window.png"));
                PressDialogKey(window, Keys.Escape);
                Require(calls == 2 && window.IsDisposed, "Closing did not dismiss completed setup");
            }
            using (var window = new SetupWindow(false, version, runtime, runtime, install))
            {
                var target = (TextBox)window.Controls.Find("destination", true)[0];
                Require(target.Text == runtime && ((Button)window.AcceptButton).Text == "更新", "Update did not start with the registered path");
                target.Text = selected;
                Require(((Button)window.AcceptButton).Text == "迁移并更新", "Location change was not reflected by the update action");
                Render(window, Path.Combine(output, "setup-move-window.png"));
            }
            using (var window = new SetupWindow(true, version, runtime, runtime, (target, shortcut) => {
                Interlocked.Increment(ref calls);
                return null;
            }))
            {
                Render(window, Path.Combine(output, "uninstall-window.png"));
                PressDialogKey(window, Keys.Escape);
                Require(calls == 2 && window.IsDisposed, "Cancel invoked uninstallation");
            }
            VerifyScaledWindow(version, output, defaultPath, install);
            Thread.CurrentThread.CurrentUICulture = new CultureInfo("en-US");
            using (var window = new SetupWindow(false, version, runtime, runtime, install))
            {
                var target = (TextBox)window.Controls.Find("destination", true)[0];
                target.Text = selected;
                Render(window, Path.Combine(output, "setup-move-window-en.png"));
            }
        }

        private static void SimulateLegacyInstall(Assembly setup, Paths paths)
        {
            using (var zip = new ZipArchive(setup.GetManifestResourceStream("WeekGlass.Payload")))
                zip.ExtractToDirectory(paths.DefaultRuntime);
            Directory.CreateDirectory(Paths.Setup(paths.DefaultRuntime));
            using (var wrapped = setup.GetManifestResourceStream("WeekGlass.Uninstaller"))
            using (var output = File.Create(Paths.Uninstaller(paths.DefaultRuntime)))
                wrapped.CopyTo(output);
            using (var entry = Registry.CurrentUser.CreateSubKey(paths.UninstallKey))
            {
                entry.SetValue("DisplayName", "WeekGlass");
                entry.SetValue("DisplayVersion", Copy.Version(setup.GetName().Version));
                entry.SetValue("InstallLocation", paths.DefaultRuntime);
                entry.SetValue("UninstallString", "\"" + Paths.Uninstaller(paths.DefaultRuntime) + "\"");
            }
            // Reproduce the reported missing shortcuts on an existing installation.
        }

        [STAThread]
        public static int Main(string[] args)
        {
            Thread.CurrentThread.CurrentUICulture = new CultureInfo("zh-CN");
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (args[0] == "--ui-only")
            {
                try
                {
                    Version version = Assembly.GetExecutingAssembly().GetName().Version;
                    VerifyWindows(version, args[1], Path.Combine(Path.GetTempPath(), "WeekGlass", "Programs", "WeekGlass"));
                    Console.WriteLine("WeekGlass {0}: verified the embedded 512 px brand mark, native-size and simulated 150% rendering, Enter and Escape actions, error retry, and completion.", Copy.Version(version));
                    return 0;
                }
                catch (Exception problem) { Console.Error.WriteLine(problem); return 1; }
            }
            string fixture = Path.Combine(args[1], "fixture");
            string identity = "Viliana.WeekGlass.Smoke." + Guid.NewGuid().ToString("N");
            string support = Path.Combine(fixture, "Roaming", "Viliana", "WeekGlass");
            var paths = new Paths(Path.Combine(fixture, "Programs", "WeekGlass"),
                Path.Combine(fixture, "Start Menu", "WeekGlass.lnk"), Path.Combine(fixture, "Desktop", "WeekGlass.lnk"),
                support, identity, @"Local\" + identity + ".app");
            try
            {
                Assembly setup = Assembly.LoadFile(Path.GetFullPath(args[0]));
                Version version = setup.GetName().Version;
                var installation = new Installation(paths, version);
                Directory.CreateDirectory(support);
                // A synthetic settings marker, never a copy of an actual user database.
                string settings = Path.Combine(support, "preferences.json");
                File.WriteAllText(settings, "{}");
                string runtime = Path.Combine(fixture, "用户目录 With Spaces", "周日历");
                Directory.CreateDirectory(runtime);
                Require(Install(setup, installation, runtime) == runtime, "Fresh custom install did not return chosen location");
                Require(!Directory.Exists(paths.DefaultRuntime), "Fresh install ignored the custom location");
                int count = 0;
                using (var zip = new ZipArchive(setup.GetManifestResourceStream("WeekGlass.Payload")))
                    foreach (ZipArchiveEntry entry in zip.Entries)
                    {
                        if (entry.Name.Length == 0) continue;
                        var installed = new FileInfo(Path.Combine(runtime, entry.FullName));
                        Require(installed.Exists && installed.Length == entry.Length, "Payload file missing or truncated: " + entry.FullName);
                        count++;
                    }
                VerifyShortcut(paths.StartShortcut, runtime);
                VerifyShortcut(paths.DesktopShortcut, runtime);
                VerifyRegistration(paths, runtime, version);
                installation.Uninstall(runtime);
                Require(!Directory.Exists(runtime) && !Directory.Exists(Paths.Setup(runtime)) &&
                    !File.Exists(paths.StartShortcut) && !File.Exists(paths.DesktopShortcut), "Uninstallation left program files or links");

                if (args.Length > 3) SimulateLegacyInstall(Assembly.LoadFile(Path.GetFullPath(args[3])), paths);
                else Install(setup, installation, paths.DefaultRuntime, false);
                Require(installation.RegisteredRuntime() == paths.DefaultRuntime, "Existing installation not detected");
                Install(setup, installation, paths.DefaultRuntime);
                VerifyShortcut(paths.StartShortcut, paths.DefaultRuntime);
                VerifyShortcut(paths.DesktopShortcut, paths.DefaultRuntime);
                VerifyRegistration(paths, paths.DefaultRuntime, version);

                string marker = Path.Combine(paths.DefaultRuntime, "updater-test-marker");
                File.WriteAllText(marker, "simulated updated file");
                try
                {
                    new Installation(paths, new Version(version.Major, version.Minor, version.Build, version.Revision - 1))
                        .Install(runtime, true, Stream.Null, Stream.Null);
                    throw new Exception("Older package unexpectedly installed at a different destination");
                }
                catch (InvalidOperationException error) { Require(error.Message.Contains("较新"), "Wrong downgrade error: " + error.Message); }

                string occupied = Path.Combine(fixture, "Occupied Folder");
                Directory.CreateDirectory(occupied);
                string unrelated = Path.Combine(occupied, "notes.txt");
                File.WriteAllText(unrelated, "keep");
                try { Install(setup, installation, occupied); throw new Exception("Occupied destination unexpectedly replaced"); }
                catch (IOException failure) { Require(failure.Message.Contains("空的"), "Wrong occupied folder error"); }
                Require(File.ReadAllText(unrelated) == "keep", "Installation changed unrelated files");
                try { Install(setup, installation, support); throw new Exception("Settings directory unexpectedly accepted"); }
                catch (IOException failure) { Require(failure.Message.Contains("独立"), "Wrong settings folder error"); }

                using (var lockShortcut = File.Open(paths.DesktopShortcut, FileMode.Open, FileAccess.Read, FileShare.None))
                {
                    try { Install(setup, installation, runtime); throw new Exception("Locked desktop shortcut unexpectedly replaced"); }
                    catch (IOException) { }
                }
                Require(File.Exists(marker) && !Directory.Exists(runtime), "Setup did not roll back a failed relocation");
                VerifyShortcut(paths.StartShortcut, paths.DefaultRuntime);
                VerifyShortcut(paths.DesktopShortcut, paths.DefaultRuntime);
                VerifyRegistration(paths, paths.DefaultRuntime, version);

                Install(setup, installation, runtime, false);
                Require(!Directory.Exists(paths.DefaultRuntime) && !Directory.Exists(Paths.Setup(paths.DefaultRuntime)), "Old location was not retired");
                Require(!File.Exists(paths.DesktopShortcut), "Desktop shortcut was kept after opting out");
                VerifyShortcut(paths.StartShortcut, runtime);
                VerifyRegistration(paths, runtime, version);

                using (var ready = new ManualResetEvent(false))
                using (var release = new ManualResetEvent(false))
                {
                    var owner = new Thread(() => {
                        using (var mutex = new Mutex(true, paths.AppMutex))
                        {
                            ready.Set();
                            release.WaitOne();
                            mutex.ReleaseMutex();
                        }
                    });
                    owner.Start();
                    ready.WaitOne();
                    try
                    {
                        try { installation.Uninstall(runtime); throw new Exception("Running application unexpectedly removed"); }
                        catch (InvalidOperationException error) { Require(error.Message.Contains("托盘"), "Wrong running application error: " + error.Message); }
                    }
                    finally { release.Set(); owner.Join(); }
                }

                // Simulate the signed updater's complete runtime directory swap.
                string previous = Path.Combine(fixture, "previous-app");
                Directory.Move(runtime, previous);
                Directory.CreateDirectory(runtime);
                File.Copy(Path.Combine(previous, "weekglass.exe"), Paths.Application(runtime));
                VerifyShortcut(paths.StartShortcut, runtime);
                VerifyRegistration(paths, runtime, version);
                installation.Uninstall(runtime);
                Require(!Directory.Exists(runtime) && !Directory.Exists(Paths.Setup(runtime)) && !File.Exists(paths.StartShortcut), "Uninstallation left files or links");
                Require(installation.RegisteredRuntime() == null, "Uninstallation left the Installed Apps entry");
                Require(File.ReadAllText(settings) == "{}", "Uninstallation changed application settings");

                VerifyWindows(version, args[2], runtime);
                Console.WriteLine("WeekGlass {0}: verified {1} files at a custom Unicode path, both shortcuts, Installed Apps, in-place upgrade, downgrade guard, relocation rollback and success, desktop opt-out, running-app guard, updater swap, uninstall, settings retention and setup UI, including the embedded 512 px brand mark and native-size and simulated 150% rendering.", Copy.Version(version), count);
                return 0;
            }
            catch (Exception problem) { Console.Error.WriteLine(problem); return 1; }
            finally { Registry.CurrentUser.DeleteSubKeyTree(paths.UninstallKey, false); }
        }
    }
}

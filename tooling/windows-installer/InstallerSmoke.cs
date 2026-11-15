using System;
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

        private static void Install(Assembly setup, Installation installation)
        {
            using (Stream payload = setup.GetManifestResourceStream("WeekGlass.Payload"))
            using (Stream uninstaller = setup.GetManifestResourceStream("WeekGlass.Uninstaller"))
                installation.Install(payload, uninstaller);
        }

        private static void VerifyShortcut(Paths paths)
        {
            object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true));
            try
            {
                dynamic link = ((dynamic)shell).CreateShortcut(paths.Shortcut);
                try
                {
                    Require(link.TargetPath == paths.Application, "Start-menu link target mismatch");
                    Require(link.WorkingDirectory == paths.Runtime, "Start-menu working directory mismatch");
                }
                finally { Marshal.FinalReleaseComObject(link); }
            }
            finally { Marshal.FinalReleaseComObject(shell); }
        }

        private static void Click(IButtonControl button)
        {
            // Raise the actual WinForms click event while keeping the window off the user's desktop.
            typeof(Button).GetMethod("OnClick", BindingFlags.Instance | BindingFlags.NonPublic)
                .Invoke(button, new object[] { EventArgs.Empty });
        }

        private static void Render(SetupWindow window, string output)
        {
            using (var screenshot = new Bitmap(window.Width, window.Height))
            {
                Require(window.Handle != IntPtr.Zero, "Setup window handle missing");
                foreach (Control child in window.Controls)
                    Require(child.Handle != IntPtr.Zero, "Setup child control handle missing");
                window.DrawToBitmap(screenshot, new Rectangle(0, 0, window.Width, window.Height));
                screenshot.Save(output);
            }
        }

        private static void VerifyWindows(Version version, string output)
        {
            int calls = 0;
            using (var window = new SetupWindow(false, version, () => Interlocked.Increment(ref calls)))
            {
                Render(window, Path.Combine(output, "setup-window.png"));
                Click(window.AcceptButton);
                var timer = Stopwatch.StartNew();
                while (((Button)window.AcceptButton).Text != "完成" && timer.ElapsedMilliseconds < 3000)
                {
                    Application.DoEvents();
                    Thread.Sleep(10);
                }
                Require(calls == 1 && ((Button)window.AcceptButton).Text == "完成", "Install button never reached the finish state");
                Render(window, Path.Combine(output, "setup-complete-window.png"));
                Click(window.AcceptButton);
                Require(window.IsDisposed, "Finish did not close setup");
            }
            using (var window = new SetupWindow(true, version, () => Interlocked.Increment(ref calls)))
            {
                Render(window, Path.Combine(output, "uninstall-window.png"));
                Click(window.CancelButton);
                Require(calls == 1 && window.IsDisposed, "Cancel did not close the uninstaller without removing anything");
            }
        }

        [STAThread]
        public static int Main(string[] args)
        {
            Thread.CurrentThread.CurrentUICulture = new CultureInfo("zh-CN");
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string fixture = Path.Combine(args[1], "fixture");
            string identity = "Viliana.WeekGlass.Smoke." + Guid.NewGuid().ToString("N");
            var paths = new Paths(Path.Combine(fixture, "Programs", "WeekGlass"), Path.Combine(fixture, "Start Menu", "WeekGlass.lnk"), identity, @"Local\" + identity + ".app");
            try
            {
                Assembly setup = Assembly.LoadFile(Path.GetFullPath(args[0]));
                Version version = setup.GetName().Version;
                var installation = new Installation(paths, version);
                string sqlite = Path.Combine(fixture, "Roaming", "Viliana", "WeekGlass", "weekglass.sqlite3");
                Directory.CreateDirectory(Path.GetDirectoryName(sqlite));
                File.WriteAllText(sqlite, "WeekGlass installation test fixture");

                Install(setup, installation);
                int count = 0;
                using (var zip = new ZipArchive(setup.GetManifestResourceStream("WeekGlass.Payload")))
                    foreach (ZipArchiveEntry entry in zip.Entries)
                    {
                        if (entry.Name.Length == 0) continue;
                        var installed = new FileInfo(Path.Combine(paths.Runtime, entry.FullName));
                        Require(installed.Exists && installed.Length == entry.Length, "Payload file missing or truncated: " + entry.FullName);
                        count++;
                    }
                VerifyShortcut(paths);
                Require(File.Exists(paths.Uninstaller), "Uninstall executable is absent");
                using (var entry = Registry.CurrentUser.OpenSubKey(paths.UninstallKey))
                {
                    Require(entry != null && (string)entry.GetValue("UninstallString") == "\"" + paths.Uninstaller + "\"", "Windows Installed Apps entry missing");
                    Require((string)entry.GetValue("DisplayVersion") == Copy.Version(version), "Windows Installed Apps has the wrong version");
                }

                string marker = Path.Combine(paths.Runtime, "updater-test-marker");
                File.WriteAllText(marker, "simulated updated file");
                try
                {
                    new Installation(paths, new Version(version.Major, version.Minor, version.Build, version.Revision - 1)).Install(Stream.Null, Stream.Null);
                    throw new Exception("Older package unexpectedly installed");
                }
                catch (InvalidOperationException error) { Require(error.Message.Contains("较新"), "Wrong downgrade error: " + error.Message); }

                using (var lockShortcut = File.Open(paths.Shortcut, FileMode.Open, FileAccess.Read, FileShare.None))
                {
                    try { Install(setup, installation); throw new Exception("Locked shortcut unexpectedly replaced"); }
                    catch (IOException) { }
                }
                Require(File.Exists(marker) && File.Exists(paths.Uninstaller), "Setup did not roll back after a locked shortcut");

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
                        try { installation.Uninstall(); throw new Exception("Running application unexpectedly removed"); }
                        catch (InvalidOperationException error) { Require(error.Message.Contains("托盘"), "Wrong running application error: " + error.Message); }
                    }
                    finally { release.Set(); owner.Join(); }
                }

                // Simulate the incremental updater swapping the entire runtime directory.
                string previous = Path.Combine(fixture, "previous-app");
                Directory.Move(paths.Runtime, previous);
                Directory.CreateDirectory(paths.Runtime);
                File.Copy(Path.Combine(previous, "weekglass.exe"), paths.Application);
                File.Copy(Path.Combine(previous, "updater-test-marker"), marker);
                VerifyShortcut(paths);
                Require(File.Exists(paths.Uninstaller), "Directory swap lost the uninstaller");
                installation.Uninstall();
                Require(!Directory.Exists(paths.Runtime) && !Directory.Exists(paths.Setup) && !File.Exists(paths.Shortcut), "Uninstallation left installed files or shortcut");
                using (var entry = Registry.CurrentUser.OpenSubKey(paths.UninstallKey)) Require(entry == null, "Uninstallation left the Installed Apps entry");
                Require(File.ReadAllText(sqlite) == "WeekGlass installation test fixture", "Uninstallation changed application data");

                VerifyWindows(version, args[2]);
                Console.WriteLine("WeekGlass {0}: installed {1} files; verified shortcut, Installed Apps, downgrade guard, rollback, running-app guard, updater directory swap, uninstall, data retention, and setup buttons.", Copy.Version(version), count);
                return 0;
            }
            catch (Exception problem) { Console.Error.WriteLine(problem); return 1; }
            finally { Registry.CurrentUser.DeleteSubKeyTree(paths.UninstallKey, false); }
        }
    }
}

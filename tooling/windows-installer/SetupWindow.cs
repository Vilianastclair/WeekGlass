using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WeekGlassSetup
{
    internal sealed class SetupWindow : Form
    {
        private static readonly Color Ink = Color.FromArgb(27, 35, 58);
        private static readonly Color Muted = Color.FromArgb(85, 97, 121);
        private static readonly Color Canvas = Color.FromArgb(248, 249, 253);
        private static readonly Color Border = Color.FromArgb(217, 223, 235);
        private static readonly Color Violet = Color.FromArgb(73, 63, 150);
        private readonly Func<string, bool, string> operation;
        private readonly bool uninstall;
        private readonly string initial, registered;
        private readonly Panel options, status;
        private readonly Label heading, details, actionHint;
        private readonly TextBox destination, errorDetail;
        private readonly CheckBox desktop;
        private readonly Button primary, cancel;
        private readonly ProgressBar progress;
        private readonly Bitmap logo;
        private string installed;
        private bool busy, complete, failed;

        public SetupWindow(bool uninstall, Version version, string initial, string registered, Func<string, bool, string> operation)
        {
            this.uninstall = uninstall;
            this.initial = initial;
            this.registered = registered;
            this.operation = operation;
            SuspendLayout();
            AutoScaleDimensions = new SizeF(96, 96);
            AutoScaleMode = AutoScaleMode.Dpi;
            Text = uninstall ? Copy.Text("Uninstall WeekGlass", "卸载 WeekGlass") : Copy.Text("WeekGlass Setup", "安装 WeekGlass");
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            using (Stream resource = typeof(SetupWindow).Assembly.GetManifestResourceStream("WeekGlass.Brand"))
            using (var source = new Bitmap(resource)) logo = new Bitmap(source);
            ClientSize = new Size(600, 416);
            BackColor = Canvas;
            Font = new Font("Segoe UI", 10);
            ForeColor = Ink;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterScreen;
            MinimizeBox = MaximizeBox = false;

            var header = new BrandPanel { Bounds = new Rectangle(0, 0, 600, 120) };
            header.Controls.Add(new BrandMark { Name = "brandMark", Bounds = new Rectangle(31, 28, 64, 64), Image = logo, BackColor = Color.Transparent });
            var wordmark = LabelAt("WeekGlass", 110, 29, 24, Color.White, true);
            wordmark.Name = "wordmark";
            header.Controls.Add(wordmark);
            var tagline = LabelAt(Copy.Text("Week calendar for Windows", "Windows 周日历"), 113, 76, 10, Color.FromArgb(197, 206, 234));
            tagline.Name = "tagline";
            header.Controls.Add(tagline);
            var build = LabelAt(Copy.Text("Version ", "版本 ") + Copy.Version(version), 0, 80, 9, Color.FromArgb(197, 206, 234));
            build.AutoSize = false;
            build.TextAlign = ContentAlignment.MiddleRight;
            build.Bounds = new Rectangle(401, 78, 163, 24);
            header.Controls.Add(build);

            options = new Panel { Bounds = new Rectangle(0, 120, 600, 230), TabIndex = 0 };
            options.Controls.Add(LabelAt(uninstall
                ? Copy.Text("Remove WeekGlass", "卸载 WeekGlass")
                : registered == null ? Copy.Text("Install WeekGlass", "安装 WeekGlass") : Copy.Text("Update WeekGlass", "更新 WeekGlass"),
                32, 20, 18, Ink, true));

            var introduction = LabelAt(uninstall
                ? Copy.Text("Your calendar and settings will stay on this PC.", "你的日程和偏好会继续保存在此电脑上。")
                : Copy.Text("Set up WeekGlass for your Windows account.", "为当前 Windows 账号安装。"), 34, 62, 10, Muted);
            options.Controls.Add(introduction);

            var pathLabel = LabelAt(uninstall ? Copy.Text("Installation to remove", "将卸载的程序位置") : Copy.Text("Installation folder", "安装位置"), 34, 104, 10, Ink, true);
            options.Controls.Add(pathLabel);
            destination = new TextBox {
                Name = "destination", AccessibleName = pathLabel.Text,
                Location = new Point(35, 131), Width = uninstall ? 530 : 430, Text = initial,
                BackColor = Color.White, ForeColor = Ink, BorderStyle = BorderStyle.FixedSingle,
                AutoSize = false, Height = 36, Multiline = true, AcceptsReturn = false, WordWrap = false,
                ReadOnly = uninstall, TabIndex = 0
            };
            // A padded single-line edit keeps path text aligned with the adjacent action.
            var field = new Panel { Bounds = new Rectangle(34, 130, uninstall ? 532 : 432, 36), BackColor = Border, TabIndex = 0 };
            var inset = new Panel { Bounds = new Rectangle(1, 1, field.Width - 2, field.Height - 2), BackColor = Color.White, TabIndex = 0 };
            destination.Bounds = new Rectangle(10, 7, inset.Width - 20, 23);
            destination.BorderStyle = BorderStyle.None;
            destination.Multiline = false;
            inset.Controls.Add(destination);
            field.Controls.Add(inset);
            options.Controls.Add(field);
            if (!uninstall)
            {
                var browse = MakeButton(Copy.Text("Browse", "浏览"), new Rectangle(476, 130, 90, 36), false);
                browse.Name = "browse";
                browse.TabIndex = 1;
                browse.Click += Browse;
                options.Controls.Add(browse);
            }

            desktop = new CheckBox {
                Name = "desktopShortcut", Bounds = new Rectangle(34, 179, 530, 29), TabIndex = 2,
                Text = Copy.Text("Create a desktop shortcut", "创建桌面快捷方式"), Checked = true,
                Visible = !uninstall
            };
            options.Controls.Add(desktop);
            if (uninstall)
                options.Controls.Add(LabelAt(Copy.Text("This also removes the Start menu and desktop shortcuts.", "同时移除「开始」菜单和桌面上的 WeekGlass 快捷方式。"), 34, 181, 10, Muted));

            status = new Panel { Bounds = options.Bounds, Visible = false, TabIndex = 0 };
            heading = LabelAt("", 34, 43, 19, Ink, true);
            details = LabelAt("", 35, 90, 11, Muted);
            details.MaximumSize = new Size(526, 0);
            progress = new ProgressBar { Bounds = new Rectangle(35, 139, 530, 10), Style = ProgressBarStyle.Marquee, Visible = false };
            errorDetail = new TextBox {
                Bounds = new Rectangle(35, 132, 530, 65), Multiline = true, ReadOnly = true,
                ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, BackColor = Canvas, ForeColor = Muted,
                AccessibleName = Copy.Text("Error details", "错误详情"), Visible = false
            };
            status.Controls.AddRange(new Control[] { heading, details, progress, errorDetail });

            var footer = new Panel { Bounds = new Rectangle(0, 350, 600, 66), BackColor = Color.White, TabIndex = 1 };
            footer.Controls.Add(new Panel { Bounds = new Rectangle(0, 0, 600, 1), BackColor = Border });
            actionHint = LabelAt("", 34, 25, 9, Muted);
            actionHint.MaximumSize = new Size(279, 0);
            footer.Controls.Add(actionHint);
            cancel = MakeButton(Copy.Text("Cancel", "取消"), new Rectangle(318, 14, 106, 38), false);
            primary = MakeButton("", new Rectangle(434, 14, 132, 38), true);
            cancel.TabIndex = 0;
            primary.TabIndex = 1;
            primary.Click += RunOperation;
            cancel.Click += (sender, args) => Close();
            footer.Controls.AddRange(new Control[] { cancel, primary });
            Controls.AddRange(new Control[] { header, options, status, footer });
            AcceptButton = primary;
            CancelButton = cancel;
            destination.TextChanged += (sender, args) => UpdateActions();
            UpdateActions();
            ActiveControl = primary;
            ResumeLayout(true);
        }

        private static Label LabelAt(string text, int x, int y, float size, Color color, bool bold = false)
        {
            return new Label {
                Text = text, AutoSize = true, BackColor = Color.Transparent, ForeColor = color, Location = new Point(x, y),
                Font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular)
            };
        }

        private static Button MakeButton(string text, Rectangle bounds, bool emphasized)
        {
            return new GlassButton(emphasized, bounds.Height) {
                Text = text, Bounds = bounds, Cursor = Cursors.Hand, Font = new Font("Segoe UI Semibold", 10)
            };
        }

        private sealed class BrandMark : PictureBox
        {
            protected override void OnPaint(PaintEventArgs e)
            {
                e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                e.Graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                e.Graphics.DrawImage(Image, ClientRectangle);
            }
        }

        // Keep native Button behavior for activation, focus, mnemonics and accessibility.
        private sealed class GlassButton : Button
        {
            private readonly bool emphasized;
            private readonly int nominalHeight;
            private bool hover, mouseDown, keyDown;

            public GlassButton(bool emphasized, int nominalHeight)
            {
                this.emphasized = emphasized;
                this.nominalHeight = nominalHeight;
                FlatStyle = FlatStyle.Flat;
                UseVisualStyleBackColor = false;
                SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer |
                    ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
                BackColor = Color.Transparent;
            }

            private static GraphicsPath RoundRect(RectangleF bounds, float radius)
            {
                float diameter = radius * 2;
                var shape = new GraphicsPath();
                shape.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
                shape.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
                shape.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
                shape.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
                shape.CloseFigure();
                return shape;
            }

            protected override void OnPaint(PaintEventArgs e)
            {
                if (Width <= 1 || Height <= 1) return;
                bool pressed = keyDown || (hover && mouseDown);
                Color top, bottom, edge, text, focus;
                if (SystemInformation.HighContrast)
                {
                    top = bottom = Enabled && (emphasized || hover) ? SystemColors.Highlight : SystemColors.Control;
                    edge = SystemColors.WindowText;
                    text = !Enabled ? SystemColors.GrayText : (emphasized || hover) ? SystemColors.HighlightText : SystemColors.ControlText;
                    focus = text;
                }
                else if (!Enabled)
                {
                    top = bottom = Color.FromArgb(236, 238, 246);
                    edge = Border;
                    text = Muted;
                    focus = Ink;
                }
                else if (emphasized)
                {
                    top = pressed ? Violet : hover ? Color.FromArgb(100, 88, 183) : Color.FromArgb(88, 76, 172);
                    bottom = pressed ? Color.FromArgb(63, 53, 133) : Violet;
                    edge = Color.FromArgb(116, 105, 188);
                    text = Color.White;
                    focus = Color.FromArgb(218, 225, 255);
                }
                else
                {
                    top = pressed ? Color.FromArgb(237, 239, 251) : Color.White;
                    bottom = hover || pressed ? Color.FromArgb(233, 235, 249) : Color.FromArgb(247, 248, 253);
                    edge = hover || pressed ? Color.FromArgb(189, 188, 219) : Border;
                    text = Ink;
                    focus = Violet;
                }

                float scale = Height / (float)nominalHeight;
                float line = Math.Max(1f, scale);
                float radius = 11f * scale;
                var bounds = new RectangleF(line / 2, line / 2, Width - line, Height - line);
                e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using (var path = RoundRect(bounds, radius))
                using (var fill = new LinearGradientBrush(bounds, top, bottom, LinearGradientMode.Vertical))
                using (var outline = new Pen(edge, line))
                {
                    e.Graphics.FillPath(fill, path);
                    e.Graphics.DrawPath(outline, path);
                }
                if (Focused && ShowFocusCues)
                {
                    bounds.Inflate(-3f * scale, -3f * scale);
                    using (var focusPath = RoundRect(bounds, radius - 3f * scale))
                    using (var focusPen = new Pen(focus, line))
                        e.Graphics.DrawPath(focusPen, focusPath);
                }
                var format = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine;
                if (!ShowKeyboardCues) format |= TextFormatFlags.HidePrefix;
                TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, text, format);
            }

            protected override void OnMouseEnter(EventArgs e) { hover = true; base.OnMouseEnter(e); Invalidate(); }
            protected override void OnMouseLeave(EventArgs e) { hover = false; base.OnMouseLeave(e); Invalidate(); }
            protected override void OnMouseDown(MouseEventArgs e) { mouseDown = e.Button == MouseButtons.Left; base.OnMouseDown(e); Invalidate(); }
            protected override void OnMouseCaptureChanged(EventArgs e) { if (!Capture) mouseDown = false; base.OnMouseCaptureChanged(e); Invalidate(); }
            protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space) keyDown = true; base.OnKeyDown(e); Invalidate(); }
            protected override void OnKeyUp(KeyEventArgs e) { keyDown = false; base.OnKeyUp(e); Invalidate(); }
            protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
            protected override void OnLostFocus(EventArgs e) { keyDown = false; base.OnLostFocus(e); Invalidate(); }
            protected override void OnChangeUICues(UICuesEventArgs e) { base.OnChangeUICues(e); Invalidate(); }
        }

        private void UpdateActions()
        {
            bool changing = registered != null && !Paths.Equal(destination.Text.Trim().TrimEnd('\\'), registered);
            primary.Text = uninstall ? Copy.Text("Uninstall", "卸载") : changing ? Copy.Text("Move and update", "迁移并更新")
                : registered == null ? Copy.Text("Install", "安装") : Copy.Text("Update", "更新");
            actionHint.Text = uninstall ? Copy.Text("Calendar and settings are kept", "保留日程和偏好")
                : changing ? Copy.Text("Moves program files and keeps your data", "迁移程序文件，保留日程和偏好")
                : Copy.Text("Added to the Start menu", "添加到 Windows「开始」菜单");
        }

        private void Browse(object sender, EventArgs args)
        {
            string current = Path.GetDirectoryName(initial);
            try { current = Path.GetDirectoryName(Path.GetFullPath(destination.Text)) ?? current; }
            catch (ArgumentException) { }
            catch (IOException) { }
            catch (NotSupportedException) { }
            try
            {
                string parent = FolderPicker.Select(this, current);
                if (parent != null)
                {
                    destination.Text = Paths.Equal(parent, Path.GetDirectoryName(initial))
                        ? initial : Path.Combine(parent, "WeekGlass");
                    destination.SelectionStart = destination.TextLength;
                    destination.Focus();
                }
            }
            catch (COMException error)
            {
                MessageBox.Show(this, error.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async void RunOperation(object sender, EventArgs args)
        {
            if (complete)
            {
                if (!uninstall)
                {
                    try
                    {
                        using (Process app = Process.Start(new ProcessStartInfo(Paths.Application(installed)) {
                            WorkingDirectory = installed, UseShellExecute = false
                        })) { }
                    }
                    catch (Win32Exception error)
                    {
                        MessageBox.Show(this, error.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                }
                Close();
                return;
            }
            if (failed)
            {
                failed = false;
                errorDetail.Visible = status.Visible = false;
                options.Visible = true;
                UpdateActions();
                if (!uninstall) destination.Focus();
                return;
            }
            string target = destination.Text;
            bool shortcut = desktop.Checked;
            busy = true;
            primary.Enabled = cancel.Enabled = false;
            options.Visible = false;
            status.Visible = true;
            actionHint.Text = "";
            heading.Text = uninstall ? Copy.Text("Uninstalling WeekGlass", "正在卸载 WeekGlass") : Copy.Text("Setting up WeekGlass", "正在安装 WeekGlass");
            details.Text = Copy.Text("This usually takes a few seconds.", "通常只需几秒。");
            progress.Visible = true;
            try
            {
                installed = await Task.Run(() => operation(target, shortcut));
                complete = true;
                heading.Text = uninstall ? Copy.Text("WeekGlass has been removed", "已卸载 WeekGlass") : Copy.Text("WeekGlass is ready", "WeekGlass 已就绪");
                details.Text = uninstall
                    ? Copy.Text("Your calendar and settings are still on this PC.", "你的日程和偏好仍保存在此电脑上。")
                    : shortcut ? Copy.Text("Open it from the Start menu or your desktop.", "可从「开始」菜单或桌面打开。")
                        : Copy.Text("Open it from the Start menu.", "可从「开始」菜单打开。");
                primary.Text = uninstall ? Copy.Text("Done", "完成") : Copy.Text("Open WeekGlass", "打开 WeekGlass");
                cancel.Text = Copy.Text("Close", "关闭");
                cancel.Visible = !uninstall;
            }
            catch (Exception error)
            {
                failed = true;
                heading.Text = uninstall ? Copy.Text("Could not uninstall WeekGlass", "未能卸载 WeekGlass") : Copy.Text("Could not install WeekGlass", "未能安装 WeekGlass");
                details.Text = Copy.Text("You can review the details and go back to try again.", "请查看下方说明，再返回重试。");
                errorDetail.Text = error.Message;
                errorDetail.Visible = true;
                primary.Text = Copy.Text("Go back", "返回");
            }
            finally
            {
                progress.Visible = busy = false;
                primary.Enabled = cancel.Enabled = true;
                primary.Focus();
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            int dark = 1;
            if (DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int)) != 0)
                DwmSetWindowAttribute(Handle, 19, ref dark, sizeof(int));
        }

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (busy) e.Cancel = true;
            base.OnFormClosing(e);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && logo != null) logo.Dispose();
            base.Dispose(disposing);
        }

        private sealed class BrandPanel : Panel
        {
            protected override void OnPaintBackground(PaintEventArgs e)
            {
                Rectangle bounds = ClientRectangle;
                using (var fill = new LinearGradientBrush(bounds, Color.FromArgb(23, 30, 61), Color.FromArgb(47, 42, 100), 12f))
                    e.Graphics.FillRectangle(fill, bounds);

                var graphics = e.Graphics;
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using (var grid = new Pen(Color.FromArgb(29, 160, 175, 235), 1f))
                {
                    // Calendar lines fade into the midnight header, away from the wordmark.
                    int start = bounds.Width * 61 / 100;
                    int step = Math.Max(16, bounds.Width / 18);
                    for (int x = start; x < bounds.Width; x += step)
                        graphics.DrawLine(grid, x, 0, x, bounds.Height * 62 / 100);
                    int row = Math.Max(12, bounds.Height / 5);
                    for (int y = row; y <= bounds.Height * 62 / 100; y += row)
                        graphics.DrawLine(grid, start, y, bounds.Width, y);
                    using (var eventFill = new SolidBrush(Color.FromArgb(70, 146, 155, 231)))
                        graphics.FillRectangle(eventFill, start + step + 4, row + 4, step - 8, 2 * row - 8);
                    using (var eventFill = new SolidBrush(Color.FromArgb(58, 107, 191, 220)))
                        graphics.FillRectangle(eventFill, start + 4 * step + 4, 4, step - 8, 2 * row - 8);
                }
            }
        }
    }

    internal static class FolderPicker
    {
        public static string Select(IWin32Window owner, string initial)
        {
            var dialog = (FileDialogInterface)new FileOpenDialog();
            try
            {
                dialog.SetOptions(0x20 /* PICKFOLDERS */ | 0x40 /* FORCEFILESYSTEM */ | 0x800 /* PATHMUSTEXIST */ | 0x2000000 /* DONTADDTORECENT */);
                dialog.SetTitle(Copy.Text("Choose a parent folder for WeekGlass", "选择 WeekGlass 安装目录的上一级文件夹"));
                dialog.SetOkButtonLabel(Copy.Text("Select folder", "选择文件夹"));
                dialog.SetFileNameLabel(Copy.Text("WeekGlass will be installed inside this folder", "将在此文件夹下安装 WeekGlass"));
                if (initial != null && Directory.Exists(initial))
                {
                    ShellItem folder;
                    if (SHCreateItemFromParsingName(initial, IntPtr.Zero, typeof(ShellItem).GUID, out folder) == 0)
                    {
                        try { dialog.SetFolder(folder); }
                        finally { Marshal.FinalReleaseComObject(folder); }
                    }
                }
                int result = dialog.Show(owner.Handle);
                if (result == unchecked((int)0x800704C7)) return null;
                Marshal.ThrowExceptionForHR(result);
                ShellItem selected;
                dialog.GetResult(out selected);
                try
                {
                    IntPtr filename;
                    selected.GetDisplayName(0x80058000 /* FILESYSPATH */, out filename);
                    try { return Marshal.PtrToStringUni(filename); }
                    finally { Marshal.FreeCoTaskMem(filename); }
                }
                finally { Marshal.FinalReleaseComObject(selected); }
            }
            finally { Marshal.FinalReleaseComObject(dialog); }
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHCreateItemFromParsingName(string path, IntPtr context, [MarshalAs(UnmanagedType.LPStruct)] Guid iid, out ShellItem item);

        [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
        private class FileOpenDialog { }

        [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface FileDialogInterface
        {
            [PreserveSig] int Show(IntPtr owner);
            void SetFileTypes();
            void SetFileTypeIndex();
            void GetFileTypeIndex();
            void Advise();
            void Unadvise();
            void SetOptions(uint options);
            void GetOptions();
            void SetDefaultFolder();
            void SetFolder(ShellItem folder);
            void GetFolder();
            void GetCurrentSelection();
            void SetFileName();
            void GetFileName();
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
            void GetResult(out ShellItem result);
        }

        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface ShellItem
        {
            void BindToHandler();
            void GetParent();
            void GetDisplayName(uint format, out IntPtr name);
        }
    }
}

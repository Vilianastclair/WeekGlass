# Build the Windows x64 installer

Build the Windows Flutter release and its update helper from the same source revision. Run the following in PowerShell from the repository root:

```powershell
Push-Location apps/client
flutter pub get
flutter build windows --release
$runtime = (Resolve-Path build/windows/x64/runner/Release).Path
dart compile exe tool/update_helper.dart -o (Join-Path $runtime 'weekglass_updater.exe')
Pop-Location
```

Copy the x64 Microsoft VC143 redistributable DLLs (the `x64/Microsoft.VC143.CRT` directory from Visual Studio's VC redistributables) into `$runtime`. Then create the installer:

```powershell
.\tooling\scripts\package-windows-installer.ps1 -PackageDirectory $runtime
```

The script uses Windows' built-in .NET Framework x64 compiler and writes `release/WeekGlass-Setup-<version>-Windows-x64.exe`.
To distinguish a rebuild of the installer for the same app version, pass `-InstallerRevision 2`. This adds `-r2` to the installer filename without changing the embedded app version.

To also build the portable ZIP and include the bundled user guide in the installer, compile the helper to `release/weekglass_updater.exe` instead (create `release` first). From the repository root, run `.\tooling\scripts\package-windows.ps1`, then pass its `release/WeekGlass-Windows-x64-<version>` directory to the installer script. The portable packager finds the x64 C++ runtime via the configured WeekGlass toolchain or an installed Visual Studio.

Setup installs for the current Windows account. Enter the full destination or use **Browse** to choose the parent of the WeekGlass folder. During an update, setup starts with the existing location. Choosing another location moves the program, updates its shortcuts, and preserves the separate calendar and settings data. Exit WeekGlass from the notification area before updating or uninstalling.

Setup adds WeekGlass to the Start menu and creates a desktop shortcut unless you uncheck that option. To remove the program and its shortcuts, open **Settings > Apps > Installed apps > WeekGlass** in Windows. Calendar and settings stay on the PC. Software updates still use WeekGlass's signed in-app channel.

Pass `-SmokeArtifactDirectory` for an isolated install, update, move and uninstall check with screenshots. Add `-LegacyInstaller <path>` to seed the existing installation from a previously published installer rather than the new package. The check uses temporary program and shortcut locations and its own registry entry.

The smoke check captures Browse, Cancel and Install through WinForms' native paint path in normal, hovered, pressed, disabled and keyboard-focused states. The `button-paint-*.png` sheets show 100%, 125% and 150% geometry. On a display with different scaling, the test adjusts control dimensions without changing display settings.

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

The script uses Windows' built-in .NET Framework x64 compiler and writes `release/WeekGlass-Setup-<version>-Windows-x64.exe`. Pass `-SmokeArtifactDirectory` to test the install, update and uninstall paths with an isolated fixture. The installer and uninstaller run for the current user. They leave the separate calendar and settings data directory in place; software updates still use WeekGlass's signed in-app channel.

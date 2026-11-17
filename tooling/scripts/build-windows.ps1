$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $ProjectRoot 'tooling\env.ps1')

$pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
$vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
  throw 'Visual Studio Build Tools are missing. Install Desktop development with C++ using Visual Studio Installer, including ATL and CMake.'
}

# Flutter requires current MSVC and CMake. Windows secure credential storage
# additionally needs ATL headers and libraries (not checked by flutter doctor).
$required = @(
  'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
  'Microsoft.VisualStudio.Component.VC.ATL',
  'Microsoft.VisualStudio.Component.VC.CMake.Project'
)
foreach ($component in $required) {
  $found = & $vswhere -latest -products '*' -requires $component -property installationPath
  if (-not $found) {
    throw "Missing Visual Studio component: $component. Enable the corresponding C++ tools, ATL, or CMake component in Visual Studio Installer."
  }
}

Set-Location (Join-Path $ProjectRoot 'apps\client')
flutter test test/update_version_test.dart
if ($LASTEXITCODE -ne 0) { throw 'The updater version must match pubspec before packaging.' }
flutter doctor -v
flutter build windows --release
if ($LASTEXITCODE -ne 0) {
  throw "Windows release build failed with exit code $LASTEXITCODE."
}
Write-Output 'WINDOWS_RELEASE_BUILD_SUCCESS'

<#
.SYNOPSIS
Builds a per-user WeekGlass installer from a prepared Windows x64 runtime directory.
.EXAMPLE
./tooling/scripts/package-windows-installer.ps1 -PackageDirectory C:/path/to/runtime -OutputDirectory C:/path/to/release
#>
param(
  [Parameter(Mandatory)][string]$PackageDirectory,
  [string]$OutputDirectory,
  [string]$SmokeArtifactDirectory,
  [string]$LegacyInstaller
)
$ErrorActionPreference = 'Stop'
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$package = (Get-Item -LiteralPath $PackageDirectory).FullName
$source = Join-Path $project 'tooling/windows-installer'
$icon = Join-Path $project 'apps/client/windows/runner/resources/app_icon.ico'
$brand = Join-Path $project 'apps/client/assets/brand/icon.png'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $project 'release' }

foreach ($required in @('weekglass.exe', 'weekglass_updater.exe', 'flutter_windows.dll', 'vcruntime140.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin')) {
  if (-not (Test-Path -LiteralPath (Join-Path $package $required) -PathType Leaf)) {
    throw "Incomplete Windows runtime: $required is missing. Supply the built x64 application and update helper with the Flutter data, DLLs, and Visual C++ runtime."
  }
}

$ownedApp = Join-Path $package 'weekglass.exe'
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo($ownedApp)
if ($info.ProductName -ne 'WeekGlass' -or $info.ProductVersion -notmatch '^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$') {
  throw 'The package executable is missing WeekGlass product/version metadata.'
}
$version = $Matches[1]
$build = $Matches[2]
$fileVersion = '{0}.{1}.{2}.{3}' -f $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart
if ($fileVersion -ne "$version.$build") { throw 'The product version and file version disagree.' }
$reader = [IO.BinaryReader]::new([IO.File]::OpenRead($ownedApp))
try {
  $reader.BaseStream.Position = 0x3c
  $reader.BaseStream.Position = $reader.ReadInt32()
  if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
    throw 'The package executable is not Windows x64.'
  }
} finally { $reader.Dispose() }

$packageItems = @(Get-Item -LiteralPath $package; Get-ChildItem -LiteralPath $package -Force -Recurse)
if ($packageItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -match '\.(db|sqlite|sqlite3)(-|$)' }) {
  throw 'The release directory contains a redirected item or a database. Package only the built program.'
}

$output = (New-Item -ItemType Directory -Path $OutputDirectory -Force).FullName
$filename = "WeekGlass-Setup-$version-Windows-x64.exe"
$destination = Join-Path $output $filename
if (Test-Path -LiteralPath $destination) { throw "Installer exists: $destination. Choose a fresh output directory." }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$stage = [IO.Path]::GetFullPath((Join-Path $tempRoot ('WeekGlass-Package-' + [guid]::NewGuid().ToString('N'))))
if ((Split-Path -Parent $stage) -ine $tempRoot) { throw 'Invalid packaging scratch path.' }
New-Item -ItemType Directory -Path $stage | Out-Null

try {
  $payload = Join-Path $stage 'payload.zip'
  $assemblyInfo = Join-Path $stage 'AssemblyInfo.cs'
  $uninstaller = Join-Path $stage 'Uninstall.exe'
  $setup = Join-Path $stage $filename
  $manifest = Join-Path $source 'WeekGlassSetup.manifest'
  $code = @((Join-Path $source 'WeekGlassSetup.cs'), (Join-Path $source 'SetupWindow.cs'))
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($package, $payload, [IO.Compression.CompressionLevel]::Optimal, $false, [Text.Encoding]::UTF8)
  @"
using System.Reflection;
[assembly: AssemblyTitle("WeekGlass Setup")]
[assembly: AssemblyDescription("WeekGlass Windows x64 installer")]
[assembly: AssemblyCompany("Viliana")]
[assembly: AssemblyProduct("WeekGlass")]
[assembly: AssemblyVersion("$fileVersion")]
[assembly: AssemblyFileVersion("$fileVersion")]
[assembly: AssemblyInformationalVersion("$version+$build")]
"@ | Set-Content -LiteralPath $assemblyInfo -Encoding UTF8

  $compilerArgs = @('/nologo', '/optimize+', '/platform:x64', '/codepage:65001',
    '/reference:System.Windows.Forms.dll,System.Drawing.dll,System.IO.Compression.dll,System.IO.Compression.FileSystem.dll,Microsoft.CSharp.dll',
    "/win32manifest:$manifest", "/win32icon:$icon", "/resource:$brand,WeekGlass.Brand")
  & $compiler @compilerArgs '/target:winexe' '/define:UNINSTALLER' "/out:$uninstaller" $assemblyInfo @code
  if ($LASTEXITCODE -ne 0) { throw "Uninstaller compilation failed: $LASTEXITCODE" }
  & $compiler @compilerArgs '/target:winexe' "/resource:$payload,WeekGlass.Payload" "/resource:$uninstaller,WeekGlass.Uninstaller" "/out:$setup" $assemblyInfo @code
  if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed: $LASTEXITCODE" }
  if ($SmokeArtifactDirectory) {
    $artifacts = (New-Item -ItemType Directory -Path $SmokeArtifactDirectory -Force).FullName
    $smoke = Join-Path $stage 'InstallerSmoke.exe'
    & $compiler @compilerArgs '/target:exe' '/main:WeekGlassSetup.InstallerSmoke' "/out:$smoke" $assemblyInfo @code (Join-Path $source 'InstallerSmoke.cs')
    if ($LASTEXITCODE -ne 0) { throw "Installer smoke compilation failed: $LASTEXITCODE" }
    if ($LegacyInstaller) {
      & $smoke $setup $stage $artifacts (Resolve-Path -LiteralPath $LegacyInstaller).Path
    } else {
      & $smoke $setup $stage $artifacts
    }
    if ($LASTEXITCODE -ne 0) { throw "Installer smoke failed: $LASTEXITCODE" }
  }
  [IO.File]::Copy($setup, $destination, $false)
  [pscustomobject]@{ Version = "$version+$build"; Installer = $destination; Bytes = (Get-Item -LiteralPath $destination).Length }
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force
}

# Project-local developer environment; never modifies machine or user PATH.
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$VersionConfig = Get-Content (Join-Path $PSScriptRoot 'versions.json') -Raw | ConvertFrom-Json
$ToolchainRoot = if ($env:WEEKGLASS_TOOLCHAIN_HOME) { $env:WEEKGLASS_TOOLCHAIN_HOME } else { [string]$VersionConfig.toolchainRoot }
$FlutterRoot = Join-Path $ToolchainRoot 'flutter'
$JavaHome = Join-Path $ToolchainRoot 'jdk\current'
$AndroidHome = Join-Path $ToolchainRoot 'android-sdk'
$PubCache = Join-Path $ToolchainRoot 'pub-cache'
$GradleHome = Join-Path $ToolchainRoot 'gradle-cache'
$env:WEEKGLASS_PROJECT_ROOT = $ProjectRoot
$env:WEEKGLASS_TOOLCHAIN_HOME = $ToolchainRoot
$env:FLUTTER_ROOT = $FlutterRoot
$env:JAVA_HOME = $JavaHome
$env:ANDROID_HOME = $AndroidHome
$env:ANDROID_SDK_ROOT = $AndroidHome
$env:PUB_CACHE = $PubCache
$env:GRADLE_USER_HOME = $GradleHome
$env:PATH = @((Join-Path $FlutterRoot 'bin'),(Join-Path $JavaHome 'bin'),(Join-Path $AndroidHome 'platform-tools'),(Join-Path $AndroidHome 'cmdline-tools\latest\bin'),$env:PATH) -join ';'
if (-not (Test-Path (Join-Path $FlutterRoot 'bin\flutter.bat'))) { throw "Flutter SDK is missing. Run .\tooling\scripts\bootstrap.ps1 first." }
if (-not (Test-Path (Join-Path $JavaHome 'bin\java.exe'))) { throw "Portable JDK is missing. Run .\tooling\scripts\bootstrap.ps1 first." }
if (-not (Test-Path (Join-Path $AndroidHome 'cmdline-tools\latest\bin\sdkmanager.bat'))) { throw "Android command-line tools are missing. Run .\tooling\scripts\bootstrap.ps1 first." }

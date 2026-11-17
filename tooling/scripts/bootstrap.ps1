[CmdletBinding()]
param([switch]$SkipFlutter,[switch]$SkipJava,[switch]$SkipAndroidSdk)
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Config = Get-Content (Join-Path $ProjectRoot 'tooling\versions.json') -Raw | ConvertFrom-Json
$ToolchainRoot = if ($env:WEEKGLASS_TOOLCHAIN_HOME) { $env:WEEKGLASS_TOOLCHAIN_HOME } else { [string]$Config.toolchainRoot }
$Downloads = Join-Path $ToolchainRoot 'downloads'
New-Item -ItemType Directory -Force -Path $ToolchainRoot,$Downloads | Out-Null
function Download-Verified([string]$Url,[string]$Path,[string]$Sha256) {
  if (-not (Test-Path $Path) -or ((Get-Item $Path).Length -eq 0)) {
    Write-Host "Downloading $([IO.Path]::GetFileName($Path))..." -ForegroundColor Cyan
    curl.exe -fL --retry 3 --connect-timeout 30 --output $Path $Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
  }
  if ($Sha256) {
    $actual = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256.ToLowerInvariant()) { throw "SHA-256 mismatch for $Path" }
  }
}
if (-not $SkipFlutter) {
  $zip = Join-Path $Downloads 'flutter_windows_3.47.9-stable.zip'
  Download-Verified $Config.flutter.archive $zip $Config.flutter.sha256
  $target = Join-Path $ToolchainRoot 'flutter'
  if (-not (Test-Path (Join-Path $target 'bin\flutter.bat'))) {
    $extract = Join-Path $ToolchainRoot 'flutter-extract'
    if (Test-Path $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    tar.exe -xf $zip -C $extract
    if ($LASTEXITCODE -ne 0) { throw 'Flutter archive extraction failed.' }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $extract 'flutter\*') $target -Recurse -Force
    Remove-Item -LiteralPath $extract -Recurse -Force
  }
}
if (-not $SkipJava) {
  $zip = Join-Path $Downloads 'microsoft-jdk-17.zip'
  Download-Verified $Config.java.archive $zip $Config.java.sha256
  $target = Join-Path $ToolchainRoot 'jdk\current'
  if (-not (Test-Path (Join-Path $target 'bin\java.exe'))) {
    $extract = Join-Path $ToolchainRoot 'jdk-extract'
    if (Test-Path $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    tar.exe -xf $zip -C $extract
    if ($LASTEXITCODE -ne 0) { throw 'JDK archive extraction failed.' }
    $source = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if (-not $source) { throw 'JDK archive structure was not recognized.' }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $source.FullName '*') $target -Recurse -Force
    Remove-Item -LiteralPath $extract -Recurse -Force
  }
}
if (-not $SkipAndroidSdk) {
  $zip = Join-Path $Downloads 'android-commandlinetools.zip'
  Download-Verified $Config.android.archive $zip $Config.android.sha256
  $target = Join-Path $ToolchainRoot 'android-sdk\cmdline-tools\latest'
  if (-not (Test-Path (Join-Path $target 'bin\sdkmanager.bat'))) {
    $extract = Join-Path $ToolchainRoot 'android-cli-extract'
    if (Test-Path $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    Move-Item -LiteralPath (Join-Path $extract 'cmdline-tools') -Destination $target -Force
    Remove-Item -LiteralPath $extract -Recurse -Force
  }
}
Write-Host ''
Write-Host "Toolchain prepared under $ToolchainRoot" -ForegroundColor Green

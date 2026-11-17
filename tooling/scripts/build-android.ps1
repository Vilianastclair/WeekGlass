param(
    [ValidateSet('Development', 'Bridge', 'Production')]
    [string]$SigningMode = 'Development',
    [string]$OutputApk,
    [string]$SigningDirectory = (Join-Path $HOME '.weekglass-secure/android-signing')
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $ProjectRoot 'tooling\env.ps1')
. (Join-Path $PSScriptRoot 'android-apk-signing.ps1')
$client = Join-Path $ProjectRoot 'apps/client'
$builtApk = Join-Path $client 'build/app/outputs/flutter-apk/app-release.apk'
$signed = $SigningMode -ne 'Development'
if ($signed) {
    if (-not $OutputApk) { throw "$SigningMode builds require an explicit -OutputApk for the verified signed artifact." }
    $OutputApk = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputApk)
    if ($OutputApk -eq $builtApk -or [IO.Path]::GetExtension($OutputApk) -ne '.apk' -or
        -not (Test-Path -LiteralPath (Split-Path -Parent $OutputApk) -PathType Container) -or
        (Test-Path -LiteralPath $OutputApk)) {
        throw 'Choose a new APK file in an existing directory, separate from Flutter build outputs.'
    }
    $SigningDirectory = (Resolve-Path -LiteralPath $SigningDirectory).Path
    if ($SigningDirectory -eq $ProjectRoot -or
        $SigningDirectory.StartsWith("$ProjectRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Keep Android signing inputs outside the source tree.'
    }
    $signingFiles = Get-WeekGlassAndroidSigningFiles $SigningDirectory $SigningMode
} elseif ($OutputApk) {
    throw '-OutputApk applies to Bridge or Production builds; development builds keep the Flutter output path.'
}

Push-Location -LiteralPath $client
try {
    & flutter test test/update_version_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'The updater version must match pubspec before packaging.' }
    $flutterArgs = @('build', 'apk', '--release')
    if ($signed) { $flutterArgs += @('--android-project-arg', 'weekglassUnsignedRelease=true') }
    & flutter @flutterArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $builtApk -PathType Leaf)) {
        throw 'Flutter did not complete the Android APK build.'
    }
    if ($signed) {
        $verified = New-WeekGlassSignedApk $builtApk $OutputApk $SigningMode $signingFiles
        Write-Host "$SigningMode APK: $OutputApk (verified signer SHA-256: $($verified.currentCertificateSha256))" -ForegroundColor Green
    } else {
        Write-Host "Development APK: $builtApk" -ForegroundColor Green
    }
} finally {
    Pop-Location
}

function Get-WeekGlassAndroidSigningPolicy {
    $path = Join-Path $ProjectRoot 'apps/client/android/signing.properties'
    $identity = Get-Content -LiteralPath $path -Raw | ConvertFrom-StringData
    if ($identity.legacyCertificateSha256 -notmatch '^[0-9a-f]{64}$' -or
        $identity.productionCertificateSha256 -notmatch '^[0-9a-f]{64}$' -or
        $identity.productionCertificateSha256 -eq $identity.legacyCertificateSha256 -or
        $identity.rotationMinimumSdk -ne '33') {
        throw 'Invalid WeekGlass Android signing policy.'
    }
    return $identity
}

function Invoke-WeekGlassAndroidSigningTool {
    param([string]$Tool, [string[]]$Arguments)
    $lines = @(& $Tool @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) {
        throw "$([IO.Path]::GetFileName($Tool)) failed ($LASTEXITCODE): $($lines -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ lines = $lines; text = $lines -join "`n" }
}

function Get-WeekGlassApkSignerDigest {
    param([string]$Verification, [int]$RotationMinimumSdk = 0)
    $signerLabel = if ($RotationMinimumSdk) {
        "Signer \(minSdkVersion=$RotationMinimumSdk, maxSdkVersion=2147483647\)"
    } else { 'Signer #1' }
    $match = [regex]::Match($Verification, "(?m)^$signerLabel certificate SHA-256 digest: ([0-9a-fA-F]{64})`$")
    if (-not $match.Success -or $Verification -notmatch '(?m)^Number of signers: 1$') {
        throw 'APK does not have exactly one effective verified signer.'
    }
    return $match.Groups[1].Value.ToLowerInvariant()
}

function Assert-WeekGlassApkSigning {
    param(
        [string]$Signer,
        [string]$Apk,
        [ValidateSet('Bridge', 'Production')][string]$SigningMode
    )
    $policy = Get-WeekGlassAndroidSigningPolicy
    $rotationSdk = if ($SigningMode -eq 'Production') { [int]$policy.rotationMinimumSdk } else { 0 }
    $all = Invoke-WeekGlassAndroidSigningTool $Signer @('verify', '--verbose', '--print-certs', $Apk)
    $digest = Get-WeekGlassApkSignerDigest $all.text $rotationSdk
    $expected = if ($SigningMode -eq 'Production') { $policy.productionCertificateSha256 } else { $policy.legacyCertificateSha256 }
    if ($digest -ne $expected) { throw "$SigningMode APK is missing its required signer." }

    $compatibilityDigest = $digest
    if ($SigningMode -eq 'Production') {
        if ($all.text -notmatch '(?m)^Verified using v3\.1 scheme .*: true$') {
            throw 'Production APK does not include a verified v3.1 signature.'
        }
        $older = Invoke-WeekGlassAndroidSigningTool $Signer @('verify', '--verbose', '--print-certs', '--max-sdk-version', [string]($rotationSdk - 1), $Apk)
        $compatibilityDigest = Get-WeekGlassApkSignerDigest $older.text
        if ($compatibilityDigest -ne $policy.legacyCertificateSha256) {
            throw 'Production APK cannot cover-update the existing signer on older supported Android.'
        }
        $lineage = Invoke-WeekGlassAndroidSigningTool $Signer @('lineage', '--in', $Apk, '--print-certs', '--verbose')
        $certificates = [regex]::Matches($lineage.text, '(?m)^Signer #\d+ in lineage certificate SHA-256 digest: ([0-9a-f]{64})$')
        if ($certificates.Count -ne 2 -or $certificates[0].Groups[1].Value -ne $compatibilityDigest -or
            $certificates[1].Groups[1].Value -ne $digest) {
            throw 'APK proof of rotation does not match the pinned WeekGlass signing lineage.'
        }
        $legacyCapabilities = $lineage.text.Substring($certificates[0].Index, ($certificates[1].Index - $certificates[0].Index))
        $required = @{ 'installed data' = 'true'; 'shared UID' = 'false'; 'permission' = 'false'; 'rollback' = 'false'; 'auth' = 'false' }
        foreach ($capability in $required.Keys) {
            if ($legacyCapabilities -notmatch "(?m)^Has $capability capability\s*:\s*$($required[$capability])$") {
                throw "Unexpected legacy certificate capability: $capability."
            }
        }
    } elseif ($all.text -notmatch '(?m)^Verified using v3\.1 scheme .*: false$') {
        throw 'The bridge APK must maintain the old certificate before signing rotation.'
    }

    return [pscustomobject]@{
        currentCertificateSha256 = $digest
        compatibilityCertificateSha256 = $compatibilityDigest
        rotationMinimumSdk = if ($rotationSdk) { $rotationSdk } else { $null }
        details = $all.lines
    }
}

function Get-WeekGlassAndroidSigningFiles {
    param([string]$SigningDirectory, [ValidateSet('Bridge', 'Production')][string]$SigningMode)
    # The password remains in an ACL-protected file read by apksigner, not this script.
    $files = @{
        legacyStore = Join-Path $SigningDirectory 'weekglass-legacy.p12'
        legacyPassword = Join-Path $SigningDirectory 'legacy-password'
    }
    if ($SigningMode -eq 'Production') {
        $files.productionStore = Join-Path $SigningDirectory 'weekglass-production.p12'
        $files.productionPassword = Join-Path $SigningDirectory 'production-password'
        $files.lineage = Join-Path $SigningDirectory 'weekglass-signing.lineage'
    }
    foreach ($file in $files.Values) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Required $SigningMode signing input is missing: $([IO.Path]::GetFileName($file))."
        }
    }
    $trusted = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    foreach ($path in @($SigningDirectory) + @($files.Values)) {
        $item = Get-Item -LiteralPath $path
        $access = (Get-Acl -LiteralPath $path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            @($access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $trusted }).Count -ne 0) {
            throw 'Android signing requires a directory and files accessible only to the signing user and SYSTEM.'
        }
    }
    return $files
}

function New-WeekGlassSignedApk {
    param(
        [string]$SourceApk,
        [string]$OutputApk,
        [ValidateSet('Bridge', 'Production')][string]$SigningMode,
        [hashtable]$SigningFiles
    )
    $buildTools = Join-Path $env:ANDROID_HOME "build-tools/$($VersionConfig.android.buildTools)"
    $signer = Join-Path $buildTools 'apksigner.bat'
    $aligner = Join-Path $buildTools 'zipalign.exe'
    $PSNativeCommandUseErrorActionPreference = $false
    $null = & $signer verify $SourceApk 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'Expected an unsigned Flutter release APK. No output was signed.' }
    $tempApk = Join-Path (Split-Path $OutputApk) ".weekglass-android-$([guid]::NewGuid()).apk"
    $options = @(
        'sign', '--out', $tempApk, '--debuggable-apk-permitted', 'false',
        '--v4-signing-enabled', 'false', '--lib-page-alignment', '16384',
        '--ks', $SigningFiles.legacyStore, '--ks-type', 'PKCS12', '--ks-key-alias', 'weekglass',
        '--ks-pass', "file:$($SigningFiles.legacyPassword)"
    )
    if ($SigningMode -eq 'Production') {
        $policy = Get-WeekGlassAndroidSigningPolicy
        $options += @(
            '--next-signer', '--ks', $SigningFiles.productionStore, '--ks-type', 'PKCS12', '--ks-key-alias', 'weekglass',
            '--ks-pass', "file:$($SigningFiles.productionPassword)", '--lineage', $SigningFiles.lineage,
            '--rotation-min-sdk-version', $policy.rotationMinimumSdk
        )
    }
    try {
        $null = Invoke-WeekGlassAndroidSigningTool $signer ($options + @($SourceApk))
        $verified = Assert-WeekGlassApkSigning $signer $tempApk $SigningMode
        $null = Invoke-WeekGlassAndroidSigningTool $aligner @('-c', '-P', '16', '4', $tempApk)
        [IO.File]::Move($tempApk, $OutputApk) # Refuse to overwrite an existing release.
        return $verified
    } finally {
        if (Test-Path -LiteralPath $tempApk) { Remove-Item -LiteralPath $tempApk }
    }
}

package com.viliana.weekglass.weekglass

import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.zip.ZipFile

class MainActivity : FlutterActivity() {
    private companion object {
        // Serializes query + enqueue even if a new Activity attaches to the same job.
        val updateDownloadWorker = Executors.newSingleThreadExecutor()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.viliana.weekglass/updates")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceInfo" -> result.success(mapOf(
                        "sourceApk" to applicationInfo.sourceDir,
                        "arm64" to Build.SUPPORTED_ABIS.contains("arm64-v8a"),
                    ))
                    "updateObject" -> updateDownloadWorker.execute {
                        try {
                            val state = ManagedUpdateDownloads(applicationContext).advance(call)
                            runOnUiThread { result.success(state) }
                        } catch (failure: ManagedDownloadFailure) {
                            runOnUiThread { result.error("managed_download", null, failure.reason) }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("managed_download", null, "unavailable") }
                        }
                    }
                    "verifyApk", "installApk" -> Thread {
                        try {
                            val apk = verifiedApk(call)
                            runOnUiThread {
                                try {
                                    if (call.method == "verifyApk") {
                                        result.success(true)
                                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                                        !packageManager.canRequestPackageInstalls()) {
                                        // Checking or downloading never opens permission settings.
                                        result.success("permission_required")
                                    } else {
                                        val uri = FileProvider.getUriForFile(
                                            this, "$packageName.updates", apk,
                                        )
                                        val intent = Intent(Intent.ACTION_VIEW).apply {
                                            setDataAndType(uri, "application/vnd.android.package-archive")
                                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                            clipData = ClipData.newRawUri("WeekGlass update", uri)
                                        }
                                        startActivity(intent)
                                        result.success("opened")
                                    }
                                } catch (_: Exception) {
                                    result.error("installer_unavailable", "无法打开系统安装器", null)
                                }
                            }
                        } catch (failure: ApkVerificationFailure) {
                            runOnUiThread {
                                result.error("invalid_apk", "安装包校验未通过", failure.reason)
                            }
                        } catch (_: Exception) {
                            runOnUiThread {
                                result.error("invalid_apk", "安装包校验未通过", "package_access")
                            }
                        }
                    }.start()
                    "openInstallSettings" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startActivity(Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                ))
                            }
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("settings_unavailable", "无法打开安装授权设置", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private class ApkVerificationFailure(val reason: String) : Exception(reason)

    private fun requireApk(verified: Boolean, reason: String) {
        if (!verified) throw ApkVerificationFailure(reason)
    }

    @Suppress("DEPRECATION")
    private fun verifiedApk(call: MethodCall): File {
        check(Build.SUPPORTED_ABIS.contains("arm64-v8a"))
        val expectedHash = requireNotNull(call.argument<String>("sha256"))
        require(Regex("[a-f0-9]{64}").matches(expectedHash))
        val expectedSize = requireNotNull(call.argument<Number>("size")).toLong()
        val expectedBuild = requireNotNull(call.argument<Number>("build")).toLong()
        val expectedVersion = requireNotNull(call.argument<String>("version"))
        require(expectedSize in 1..(256L * 1024 * 1024))
        val apk = File(requireNotNull(call.argument<String>("path"))).canonicalFile
        val allowed = File(filesDir, "updates/android-arm64/apks").canonicalFile
        requireApk(apk.parentFile == allowed && apk.name == "$expectedHash.apk", "file_location")
        requireApk(apk.isFile && apk.length() == expectedSize, "file_content")
        val digest = MessageDigest.getInstance("SHA-256")
        apk.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        requireApk(hex(digest.digest()) == expectedHash, "file_content")
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // Some Android releases only verify an archive's certificates when the
            // legacy flag is set; the modern flag then exposes the verified lineage.
            PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_SIGNATURES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val incoming = packageManager.getPackageArchiveInfo(apk.path, flags)
            ?: throw ApkVerificationFailure("archive_unreadable")
        val installed = packageManager.getPackageInfo(packageName, flags)
        requireApk(incoming.packageName == packageName && packageName == "com.viliana.weekglass", "package_name")
        requireApk(
            versionCode(incoming) == expectedBuild && expectedBuild > versionCode(installed) &&
                incoming.versionName == expectedVersion,
            "package_version",
        )
        val installedSigners = currentSigningCertificates(installed)
        val incomingSigners = currentSigningCertificates(incoming)
        requireApk(installedSigners.isNotEmpty(), "installed_signer_unavailable")
        requireApk(incomingSigners.isNotEmpty(), "archive_signer_unavailable")
        // PackageManager has already verified the archive's signature, including its
        // proof of rotation. Only consult that history when the effective signer changes.
        val incomingHistory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            installedSigners != incomingSigners) {
            incoming.signingInfo?.signingCertificateHistory?.map(::certificateSha256).orEmpty()
        } else emptyList()
        requireApk(
            ApkSignerPolicy.accepts(Build.VERSION.SDK_INT, installedSigners, incomingSigners, incomingHistory),
            "signer_mismatch",
        )
        ZipFile(apk).use { zip ->
            requireApk(
                zip.getEntry("lib/arm64-v8a/libapp.so") != null &&
                    zip.getEntry("lib/arm64-v8a/libflutter.so") != null,
                "archive_abi",
            )
        }
        return apk
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
        else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun currentSigningCertificates(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        return signatures?.map(::certificateSha256)?.toSet().orEmpty()
    }

    private fun certificateSha256(signature: Signature): String =
        hex(MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()))

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

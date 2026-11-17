package com.viliana.weekglass.weekglass

import android.Manifest
import android.app.Activity
import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import java.io.File

internal object UpdateNotifications {
    private const val channelId = "software_updates"
    private const val notificationId = 2021
    private const val permissionRequest = 2021

    fun requestPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED) return
        val settings = activity.getSharedPreferences("update_notifications", Context.MODE_PRIVATE)
        if (settings.getBoolean("permission_requested", false)) return
        settings.edit().putBoolean("permission_requested", true).apply()
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), permissionRequest)
    }

    fun downloaded(context: Context) =
        show(context, "更新下载完成", "点按以校验并继续安装")

    fun ready(context: Context) =
        show(context, "更新可以安装", "点按以打开 Android 安装器")

    fun dismiss(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(notificationId)
    }

    @Suppress("DEPRECATION")
    private fun show(context: Context, title: String, text: String) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (!manager.areNotificationsEnabled()) return
        val launch = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pending = PendingIntent.getActivity(
            context, notificationId, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(channelId, "软件更新", NotificationManager.IMPORTANCE_LOW),
            )
            Notification.Builder(context, channelId)
        } else {
            Notification.Builder(context).setPriority(Notification.PRIORITY_LOW)
        }
        try {
            manager.notify(notificationId, builder
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(pending)
                .setOnlyAlertOnce(true)
                .setAutoCancel(true)
                .build())
        } catch (_: SecurityException) {
            // If notification permission changes, foreground recovery still works.
        }
    }
}

/** Signals completion even if the app process stopped while DownloadManager ran. */
class UpdateDownloadReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
        if (id < 1) return
        val pending = goAsync()
        ManagedUpdateDownloads.worker.execute {
            try {
                val marker = File(context.filesDir.canonicalFile, "updates/android-arm64/managed-request")
                if (marker.canonicalFile != marker || !marker.isFile || marker.length() !in 1L..256L) {
                    return@execute
                }
                // Match the same local receipt AndroidUpdateRequest writes. Older receipts
                // only contain the manifest and download object hashes.
                val lines = marker.readLines()
                if (lines.size != 2 && lines.size != 5) return@execute
                if (lines.size == 5) {
                    val target = lines[2].toLongOrNull() ?: return@execute
                    val installed = context.packageManager.getPackageInfo(context.packageName, 0)
                    if (lines[4] != "0" || target <= installedBuild(installed)) return@execute
                }
                if (ManagedUpdateDownloads(context).completed(id, lines[1])) {
                    UpdateNotifications.downloaded(context)
                }
            } catch (_: Exception) {
                // Some devices omit completion broadcasts or notifications.
                // The transfer remains recoverable when the app next resumes.
            } finally {
                pending.finish()
            }
        }
    }
}

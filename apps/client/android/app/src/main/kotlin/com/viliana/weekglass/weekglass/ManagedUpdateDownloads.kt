package com.viliana.weekglass.weekglass

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest

internal class ManagedDownloadFailure(val reason: String) : Exception(reason)

/** DownloadManager owns the transfer. Only verified bytes enter the app's private cache. */
internal class ManagedUpdateDownloads(private val context: Context) {
    fun advance(call: MethodCall): Map<String, Any> {
        val hash = requireNotNull(call.argument<String>("sha256"))
        val size = requireNotNull(call.argument<Number>("size")).toLong()
        require(Regex("[a-f0-9]{64}").matches(hash) && size in 1..(256L * 1024 * 1024))
        val id = call.argument<Number>("id")?.toLong()
        val start = call.argument<Boolean>("start") == true
        val uri = Uri.parse("https://cloud.viliana.cn/updates/v1/objects/${hash.take(2)}/$hash")
        val label = "weekglass-update:$hash:$size"
        val manager = context.getSystemService(DownloadManager::class.java)
            ?: throw ManagedDownloadFailure("unavailable")

        // The provider's caller-owned records survive app process death.
        // The identity is written at enqueue time, so no second ID write can race it.
        val query = DownloadManager.Query()
        if (id != null) query.setFilterById(id)
        val cursor = manager.query(query) ?: throw ManagedDownloadFailure("unavailable")
        val row = cursor.use {
            var found: DownloadRow? = null
            while (it.moveToNext()) {
                if (it.getString(it.getColumnIndexOrThrow(DownloadManager.COLUMN_DESCRIPTION)) != label) {
                    continue
                }
                if (it.getString(it.getColumnIndexOrThrow(DownloadManager.COLUMN_URI)) != uri.toString()) {
                    manager.remove(it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)))
                    throw ManagedDownloadFailure("source")
                }
                found = DownloadRow(
                    id = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)),
                    status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)),
                    reason = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)),
                    received = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                    total = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)),
                )
                break
            }
            found
        }
        if (row == null) {
            if (!start || id != null) return mapOf("state" to "missing")
            val request = DownloadManager.Request(uri)
                .setTitle("WeekGlass 软件更新")
                .setDescription(label)
                .setMimeType("application/octet-stream")
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_HIDDEN)
                .addRequestHeader("Accept-Encoding", "identity")
            val newId = manager.enqueue(request)
            if (newId <= 0) throw ManagedDownloadFailure("unavailable")
            return mapOf("state" to "pending", "id" to newId, "received" to 0)
        }

        if (row.status == DownloadManager.STATUS_FAILED) {
            manager.remove(row.id)
            throw ManagedDownloadFailure(when (row.reason) {
                404, 410 -> "object_missing"
                DownloadManager.ERROR_INSUFFICIENT_SPACE -> "space"
                DownloadManager.ERROR_DEVICE_NOT_FOUND, DownloadManager.ERROR_FILE_ERROR -> "storage"
                DownloadManager.ERROR_CANNOT_RESUME -> "cannot_resume"
                else -> "system_${row.reason}"
            })
        }
        if (row.received > size || (row.total >= 0 && row.total != size)) {
            manager.remove(row.id)
            throw ManagedDownloadFailure("integrity")
        }
        val state = when (row.status) {
            DownloadManager.STATUS_PENDING -> "pending"
            DownloadManager.STATUS_RUNNING -> "running"
            DownloadManager.STATUS_PAUSED -> when (row.reason) {
                DownloadManager.PAUSED_WAITING_FOR_NETWORK -> "waiting_network"
                DownloadManager.PAUSED_QUEUED_FOR_WIFI -> "waiting_wifi"
                else -> "waiting_retry"
            }
            DownloadManager.STATUS_SUCCESSFUL -> {
                importObject(manager, row.id, hash, size)
                "ready"
            }
            else -> throw ManagedDownloadFailure("unavailable")
        }
        return mapOf("state" to state, "id" to row.id, "received" to row.received.coerceAtLeast(0))
    }

    private fun importObject(manager: DownloadManager, id: Long, hash: String, size: Long) {
        val cache = File(context.filesDir.canonicalFile, "updates/android-arm64/objects")
        val target = File(cache, hash)
        val pending = File(cache, "$hash.managed-partial")
        try {
            if ((!cache.isDirectory && !cache.mkdirs()) ||
                cache.canonicalFile != cache || target.canonicalFile != target ||
                pending.canonicalFile != pending) {
                throw ManagedDownloadFailure("storage")
            }
            val digest = MessageDigest.getInstance("SHA-256")
            var received = 0L
            val source = try {
                manager.openDownloadedFile(id)
            } catch (_: FileNotFoundException) {
                manager.remove(id)
                throw ManagedDownloadFailure("missing")
            }
            try {
                ParcelFileDescriptor.AutoCloseInputStream(source).use { input ->
                    pending.outputStream().use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            received += count
                            if (received > size) throw ManagedDownloadFailure("integrity")
                            digest.update(buffer, 0, count)
                            output.write(buffer, 0, count)
                        }
                    }
                }
                val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                if (received != size || actual != hash) throw ManagedDownloadFailure("integrity")
                if (!pending.renameTo(target)) throw ManagedDownloadFailure("storage")
            } finally {
                pending.delete()
            }
        } catch (failure: ManagedDownloadFailure) {
            if (failure.reason == "integrity") manager.remove(id)
            throw failure
        } catch (_: IOException) {
            // Keep a successfully transferred job if the private cache cannot be written yet.
            throw ManagedDownloadFailure("storage")
        }
        manager.remove(id)
    }

    private data class DownloadRow(
        val id: Long,
        val status: Int,
        val reason: Int,
        val received: Long,
        val total: Long,
    )
}

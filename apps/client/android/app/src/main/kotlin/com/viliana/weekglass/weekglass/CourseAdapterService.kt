package com.viliana.weekglass.weekglass

import android.app.Service
import android.content.Intent
import android.os.*
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.OutputStream
import java.io.PrintStream
import org.weekglass.courseadapter.Engine

// Pass a descriptor over Binder, not the timetable (Binder transactions are size-limited).
// The length prefix lets both sides use the same socket without writing a temporary file.
internal fun ParcelFileDescriptor.readTextFrame(limit: Int): String {
    return DataInputStream(ParcelFileDescriptor.AutoCloseInputStream(dup())).use { input ->
        val size = input.readInt()
        require(size in 1..limit)
        ByteArray(size).also(input::readFully).toString(Charsets.UTF_8)
    }
}

internal fun ParcelFileDescriptor.writeTextFrame(text: String, limit: Int) {
    val bytes = text.toByteArray(Charsets.UTF_8)
    require(bytes.size in 1..limit)
    DataOutputStream(ParcelFileDescriptor.AutoCloseOutputStream(dup())).use {
        it.writeInt(bytes.size)
        it.write(bytes)
        it.flush()
    }
}

// jsonEncode may expand a 4 MiB source to six ASCII bytes per character.
internal const val REQUEST_LIMIT = 24 * 1024 * 1024 + 1024
internal const val REPLY_LIMIT = 8 * 1024 * 1024

class CourseAdapterService : Service() {
    @Volatile private var running = false

    override fun onCreate() {
        super.onCreate()
        // Some historical school adapters print intermediate course data. Never send it to logcat.
        val sink = PrintStream(object : OutputStream() {
            override fun write(b: Int) {}
            override fun write(b: ByteArray, off: Int, len: Int) {}
        })
        System.setOut(sink)
        System.setErr(sink)
    }

    override fun onBind(intent: Intent): IBinder = Messenger(Handler(Looper.getMainLooper()) { message ->
        val fd = message.obj as? ParcelFileDescriptor ?: return@Handler false
        running = true
        Thread {
            try {
                fd.use {
                    val response = Engine.handle(it.readTextFrame(REQUEST_LIMIT))
                    it.writeTextFrame(response, REPLY_LIMIT)
                }
            } catch (_: Exception) {
                // A closed pipe reports failure to the client without exposing timetable text.
            } catch (_: LinkageError) {
                // Treat an incomplete install as an unavailable parser, not an app crash.
            } finally {
                running = false
            }
        }.start()
        true
    }).binder

    override fun onDestroy() {
        super.onDestroy()
        // Unbinding at the deadline stops even a parser that ignores thread interruption.
        // This process contains only this isolated service, never the Flutter application.
        if (running) Process.killProcess(Process.myPid())
    }
}

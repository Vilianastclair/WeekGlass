package com.viliana.weekglass.weekglass

import android.content.*
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class CourseAdapterBridge(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var current: Read? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "com.viliana.weekglass/courseadapter").setMethodCallHandler { call, result ->
            val text = call.arguments as? String
            when {
                call.method != "handle" -> result.notImplemented()
                text == null -> result.error("INVALID_REQUEST", null, null)
                current != null -> result.error("BUSY", null, null)
                else -> Read(text, result).also { current = it }.start()
            }
        }
    }

    private inner class Read(val input: String, val result: MethodChannel.Result) : ServiceConnection {
        var bound = false
        val timeout = Runnable { finish("TIMEOUT") }

        fun start() {
            try {
                bound = context.bindService(Intent(context, CourseAdapterService::class.java),
                    this, Context.BIND_AUTO_CREATE)
                if (bound) main.postDelayed(timeout, 14000L) else finish("UNAVAILABLE")
            } catch (_: Exception) {
                finish("UNAVAILABLE")
            }
        }

        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            if (current !== this) return
            Thread {
                try {
                    val sockets = ParcelFileDescriptor.createSocketPair()
                    val reply = sockets[0].use { local ->
                        sockets[1].use { remote ->
                            Messenger(service).send(Message.obtain(null, 1, remote))
                        }
                        local.writeTextFrame(input, REQUEST_LIMIT)
                        local.readTextFrame(REPLY_LIMIT)
                    }
                    main.post { finish(null, reply) }
                } catch (_: Exception) {
                    main.post { finish("UNAVAILABLE") }
                }
            }.start()
        }

        override fun onServiceDisconnected(name: ComponentName) = finish("UNAVAILABLE")
        override fun onBindingDied(name: ComponentName) = finish("UNAVAILABLE")
        override fun onNullBinding(name: ComponentName) = finish("UNAVAILABLE")

        fun finish(error: String?, reply: String? = null) {
            if (current !== this) return
            current = null
            main.removeCallbacks(timeout)
            if (bound) context.unbindService(this)
            if (error == null) result.success(reply) else result.error(error, null, null)
        }
    }
}

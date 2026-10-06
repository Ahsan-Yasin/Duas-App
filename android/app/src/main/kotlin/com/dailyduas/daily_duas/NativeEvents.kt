package com.dailyduas.daily_duas

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** EventChannel 'daily_duas/native_events' sink, usable from services and receivers in this process. */
object NativeEvents : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    val hasListener: Boolean get() = sink != null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun emit(event: Map<String, Any?>) {
        main.post {
            try {
                sink?.success(event)
            } catch (_: Exception) {
                // Engine detached; Dart pulls state on resume (get_ringing / get_events).
            }
        }
    }
}

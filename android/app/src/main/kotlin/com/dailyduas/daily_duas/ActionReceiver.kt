package com.dailyduas.daily_duas

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Notification actions that need no UI: snooze, dismiss, stop (also the ringing notification's delete
 * intent). "Start reciting" is an activity PendingIntent instead, because notification trampolines
 * (receiver -> startActivity) are blocked on Android 12+.
 */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = when (intent.action) {
            ACTION_SNOOZE -> "snooze"
            ACTION_DISMISS -> "dismiss"
            ACTION_STOP -> "stop"
            else -> return
        }
        val reminderId = intent.getIntExtra(EXTRA_REMINDER_ID, Int.MIN_VALUE)
        if (reminderId == Int.MIN_VALUE) return
        AlarmEngine.perform(
            context.applicationContext, action, reminderId, intent.getLongExtra(EXTRA_OCCURRENCE_MS, 0L),
        )
    }

    companion object {
        const val ACTION_SNOOZE = "com.dailyduas.daily_duas.ACTION_SNOOZE"
        const val ACTION_DISMISS = "com.dailyduas.daily_duas.ACTION_DISMISS"
        const val ACTION_STOP = "com.dailyduas.daily_duas.ACTION_STOP"
        const val EXTRA_REMINDER_ID = "reminder_id"
        const val EXTRA_OCCURRENCE_MS = "occurrence_ms"
    }
}

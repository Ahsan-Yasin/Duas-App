package com.dailyduas.daily_duas

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Fired by AlarmManager. Main alarms re-arm next week first, then the ring starts. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AlarmScheduler.ACTION_FIRE) return
        val c = context.applicationContext
        val reminderId = intent.getIntExtra(AlarmScheduler.EXTRA_REMINDER_ID, Int.MIN_VALUE)
        val kind = intent.getStringExtra(AlarmScheduler.EXTRA_KIND) ?: return
        if (reminderId == Int.MIN_VALUE) return
        val weekday = intent.getIntExtra(AlarmScheduler.EXTRA_WEEKDAY, 0)
        // AlarmManager's wake lock ends with onReceive: keep the CPU awake until RingService holds its own.
        WakeLocks.acquireHandoff(c)
        var handedOff = false
        try {
            handedOff = AlarmEngine.onFire(
                c, reminderId, kind, weekday, intent.getLongExtra(AlarmScheduler.EXTRA_TRIGGER_AT, 0L),
            )
        } finally {
            if (!handedOff) WakeLocks.releaseHandoff() // no ring service start: nothing to hand off
        }
    }
}

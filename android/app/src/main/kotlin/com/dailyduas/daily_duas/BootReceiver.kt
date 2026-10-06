package com.dailyduas.daily_duas

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-arms all alarms after reboot (also before the first unlock), clock/zone changes, app update and
 * exact-alarm permission grant.
 * Exported only so system broadcasts arrive on every OEM; all listed actions are protected broadcasts,
 * anything else is ignored, so a spoofed intent can at most cause a harmless re-arm.
 * Never rings from here (Android 15 restricts FGS starts from BOOT_COMPLETED).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in ACTIONS) return
        val c = context.applicationContext
        Notifications.ensureChannels(c)
        AlarmScheduler.rescheduleAll(c)
    }

    private companion object {
        val ACTIONS = setOf(
            // Before the first unlock (direct boot): re-arm from device-protected storage. BOOT_COMPLETED
            // follows after unlock and re-runs the idempotent rescheduleAll.
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED",
        )
    }
}

package com.dailyduas.daily_duas

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build

/**
 * Arms/cancels AlarmManager alarms. Request codes (ARCHITECTURE.md section 7): main id*10+weekday,
 * snooze id*10+8, nag id*10+9, test 999990 (test snooze 999998, test nag 999999).
 * Every ring uses setAlarmClock: exempt from Doze/App Standby/Battery Saver and allowed to start a
 * foreground service from the background.
 */
object AlarmScheduler {
    const val ACTION_FIRE = "com.dailyduas.daily_duas.ALARM_FIRE"
    const val EXTRA_REMINDER_ID = "reminder_id"
    const val EXTRA_KIND = "kind"
    const val EXTRA_WEEKDAY = "weekday"
    const val EXTRA_TRIGGER_AT = "trigger_at_ms"
    private const val REQ_SHOW = 777001
    private const val STALE_CHAIN_GRACE_MS = 10 * 60_000L

    fun requestCode(reminderId: Int, kind: String, weekday: Int): Int =
        if (reminderId == TEST_REMINDER_ID) {
            when (kind) {
                AlarmKind.SNOOZE -> 999998
                AlarmKind.NAG -> 999999
                else -> 999990
            }
        } else {
            when (kind) {
                AlarmKind.SNOOZE -> reminderId * 10 + 8
                AlarmKind.NAG -> reminderId * 10 + 9
                else -> reminderId * 10 + weekday
            }
        }

    private fun alarmManager(c: Context): AlarmManager = c.getSystemService(AlarmManager::class.java)

    fun canExact(c: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager(c).canScheduleExactAlarms()

    // Identity = explicit component + action + data + request code (extras are not part of it).
    private fun fireIntent(c: Context, code: Int): Intent =
        Intent(c, AlarmReceiver::class.java).setAction(ACTION_FIRE).setData(Uri.parse("dailyduas://alarm/$code"))

    private fun operation(c: Context, code: Int, flags: Int, fill: (Intent.() -> Unit)? = null): PendingIntent? {
        val intent = fireIntent(c, code)
        fill?.invoke(intent)
        return PendingIntent.getBroadcast(c, code, intent, flags or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun showIntent(c: Context): PendingIntent = PendingIntent.getActivity(
        c, REQ_SHOW, MainActivity.launchIntent(c, MainActivity.LAUNCH_OPEN, null),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun exists(c: Context, code: Int): Boolean = operation(c, code, PendingIntent.FLAG_NO_CREATE) != null

    fun arm(c: Context, reminderId: Int, kind: String, weekday: Int, triggerAtMs: Long) {
        val code = requestCode(reminderId, kind, weekday)
        val op = operation(c, code, PendingIntent.FLAG_UPDATE_CURRENT) {
            putExtra(EXTRA_REMINDER_ID, reminderId)
            putExtra(EXTRA_KIND, kind)
            putExtra(EXTRA_WEEKDAY, weekday)
            putExtra(EXTRA_TRIGGER_AT, triggerAtMs)
        } ?: return
        val am = alarmManager(c)
        try {
            if (canExact(c)) {
                am.setAlarmClock(AlarmManager.AlarmClockInfo(triggerAtMs, showIntent(c)), op)
            } else {
                // No exact permission (only possible on API 31-32 where SCHEDULE_EXACT_ALARM is revocable):
                // setExactAndAllowWhileIdle needs the same permission, so the only legal fallback is the
                // inexact allow-while-idle alarm. The Reliability screen tells the user to grant access.
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMs, op)
            }
        } catch (_: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMs, op)
        }
        AlarmStore.putScheduled(c, ScheduledEntry(code, reminderId, weekday, kind, triggerAtMs))
    }

    fun cancel(c: Context, code: Int) {
        operation(c, code, PendingIntent.FLAG_NO_CREATE)?.let {
            alarmManager(c).cancel(it)
            it.cancel()
        }
        AlarmStore.removeScheduled(c, code)
    }

    fun cancel(c: Context, reminderId: Int, kind: String) = cancel(c, requestCode(reminderId, kind, 0))

    /** Stores [reminders] as the full desired state and makes AlarmManager match it. */
    fun sync(c: Context, reminders: List<NativeReminder>) {
        AlarmStore.setReminders(c, reminders)
        apply(c, reminders)
    }

    /** Re-arms everything from the store (boot, time/zone change, update, permission grant, app start). */
    fun rescheduleAll(c: Context) = apply(c, AlarmStore.reminders(c))

    private fun apply(c: Context, reminders: List<NativeReminder>) {
        val now = System.currentTimeMillis()
        val byId = reminders.associateBy { it.id }
        val desired = HashSet<Int>()
        for (r in reminders) if (r.enabled) for (d in r.days) desired += requestCode(r.id, AlarmKind.MAIN, d)

        // 1. Cancel stale entries we know about.
        for (e in AlarmStore.scheduled(c)) {
            when (e.kind) {
                AlarmKind.MAIN -> if (e.code !in desired) cancel(c, e.code)
                AlarmKind.SNOOZE, AlarmKind.NAG -> if (e.reminderId != TEST_REMINDER_ID) {
                    val r = byId[e.reminderId]
                    if (r == null || !r.enabled) cancel(c, e.code)
                }
            }
        }
        // 2. Cancel untracked main alarms of known reminders (e.g. weekday removed, store cleared).
        for (r in reminders) for (d in 1..7) {
            val code = requestCode(r.id, AlarmKind.MAIN, d)
            if (code !in desired && exists(c, code)) cancel(c, code)
        }
        // 3. Arm every enabled reminder x weekday at its next occurrence (setAlarmClock replaces in place).
        for (r in reminders) if (r.enabled) for (d in r.days) {
            arm(c, r.id, AlarmKind.MAIN, d, NextOccurrence.nextMs(r.hour, r.minute, d, now))
        }
        // 4. Re-arm pending one-shot alarms (AlarmManager forgets everything at reboot). One that was due
        //    while the phone was off rings shortly after if it is recent, else it is dropped.
        for (e in AlarmStore.scheduled(c)) {
            if (e.kind == AlarmKind.MAIN) continue
            when {
                e.triggerAtMs > now -> arm(c, e.reminderId, e.kind, e.weekday, e.triggerAtMs)
                now - e.triggerAtMs <= STALE_CHAIN_GRACE_MS -> arm(c, e.reminderId, e.kind, e.weekday, now + 30_000L)
                else -> cancel(c, e.code)
            }
        }
    }

    fun scheduledList(c: Context): List<Map<String, Any?>> =
        AlarmStore.scheduled(c).sortedBy { it.triggerAtMs }.map { it.toMap(exists(c, it.code)) }

    fun nextAlarmMs(c: Context): Long? {
        val now = System.currentTimeMillis()
        return AlarmStore.scheduled(c).map { it.triggerAtMs }.filter { it > now }.minOrNull()
    }
}

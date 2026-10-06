package com.dailyduas.daily_duas

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.text.format.DateFormat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.os.UserManagerCompat
import java.util.Date

/** Notification channels and builders for ringing and missed alarms. */
object Notifications {
    const val CH_ALARMS = "alarms"
    const val CH_MISSED = "missed"
    const val ID_RINGING = 4210
    private const val MISSED_BASE = 50_000
    private const val REQ_RING = 100_000
    private const val REQ_START = 200_000
    private const val REQ_ACTION = 300_000
    private const val COLOR = 0xFF0F6E5A.toInt()

    fun missedId(reminderId: Int) = MISSED_BASE + reminderId

    fun ensureChannels(c: Context) {
        val nm = c.getSystemService(NotificationManager::class.java) ?: return
        val alarms = NotificationChannel(CH_ALARMS, c.getString(R.string.channel_alarms), NotificationManager.IMPORTANCE_HIGH).apply {
            description = c.getString(R.string.channel_alarms_desc)
            setSound(null, null) // RingService plays the tone on the alarm stream
            enableVibration(false) // RingService vibrates
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setShowBadge(false)
        }
        val missed = NotificationChannel(CH_MISSED, c.getString(R.string.channel_missed), NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = c.getString(R.string.channel_missed_desc)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        nm.createNotificationChannels(listOf(alarms, missed))
    }

    /** True when the app may post notifications and the alarms channel is not blocked. */
    fun alarmsVisible(c: Context): Boolean {
        val compat = NotificationManagerCompat.from(c)
        if (!compat.areNotificationsEnabled()) return false
        val ch = c.getSystemService(NotificationManager::class.java)?.getNotificationChannel(CH_ALARMS) ?: return true
        return ch.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun timeText(c: Context, ms: Long): String = DateFormat.getTimeFormat(c).format(Date(ms))

    private fun activityPi(c: Context, action: String, base: Int, r: Ring): PendingIntent = PendingIntent.getActivity(
        c, base + r.reminderId, MainActivity.launchIntent(c, action, r),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun actionPi(c: Context, action: String, r: Ring): PendingIntent = PendingIntent.getBroadcast(
        c, REQ_ACTION + r.reminderId,
        Intent(c, ActionReceiver::class.java).setAction(action)
            .putExtra(ActionReceiver.EXTRA_REMINDER_ID, r.reminderId)
            .putExtra(ActionReceiver.EXTRA_OCCURRENCE_MS, r.occurrenceMs),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun title(c: Context, r: Ring) = r.label.ifBlank { c.getString(R.string.alarm_default_title) }

    fun buildRinging(c: Context, r: Ring): Notification {
        val full = activityPi(c, MainActivity.LAUNCH_RING, REQ_RING, r)
        val text = buildString {
            append(timeText(c, r.occurrenceMs))
            if (r.routineName.isNotBlank()) append(" · ").append(r.routineName)
        }
        val b = NotificationCompat.Builder(c, CH_ALARMS)
            .setSmallIcon(R.drawable.ic_stat_alarm)
            .setColor(COLOR)
            .setContentTitle(title(c, r))
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setWhen(r.occurrenceMs)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(full)
            // Android 13+ lets users swipe FGS notifications away: treat it as "stop" (missed + nag).
            .setDeleteIntent(actionPi(c, ActionReceiver.ACTION_STOP, r))
            .addAction(0, c.getString(R.string.action_start), activityPi(c, MainActivity.LAUNCH_START, REQ_START, r))
        // Before the first unlock after a reboot (direct boot) MainActivity cannot start over the keyguard, so
        // there is no full-screen intent; the tone, Snooze and Dismiss still work, and the content/Start
        // intents ask for the unlock first.
        if (UserManagerCompat.isUserUnlocked(c)) b.setFullScreenIntent(full, true)
        if (r.snoozesLeft > 0) {
            b.addAction(0, c.getString(R.string.action_snooze, r.snoozeMinutes), actionPi(c, ActionReceiver.ACTION_SNOOZE, r))
        }
        b.addAction(0, c.getString(R.string.action_dismiss), actionPi(c, ActionReceiver.ACTION_DISMISS, r))
        return b.build()
    }

    fun buildPlaceholder(c: Context): Notification = NotificationCompat.Builder(c, CH_ALARMS)
        .setSmallIcon(R.drawable.ic_stat_alarm)
        .setColor(COLOR)
        .setContentTitle(c.getString(R.string.app_name))
        .setContentText(c.getString(R.string.placeholder_text))
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .build()

    /** Persistent "Missed — tap to start" notification. */
    fun postMissed(c: Context, r: Ring) {
        val start = activityPi(c, MainActivity.LAUNCH_START, REQ_START, r)
        val n = NotificationCompat.Builder(c, CH_MISSED)
            .setSmallIcon(R.drawable.ic_stat_alarm)
            .setColor(COLOR)
            .setContentTitle(c.getString(R.string.missed_title, title(c, r)))
            .setContentText(c.getString(R.string.missed_text, timeText(c, r.occurrenceMs)))
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setWhen(r.occurrenceMs)
            .setContentIntent(start)
            .addAction(0, c.getString(R.string.action_start), start)
            .addAction(0, c.getString(R.string.action_dismiss), actionPi(c, ActionReceiver.ACTION_DISMISS, r))
            .build()
        try {
            NotificationManagerCompat.from(c).notify(missedId(r.reminderId), n)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS denied: the in-app missed banner still covers it.
        }
    }

    fun cancelMissed(c: Context, reminderId: Int) {
        NotificationManagerCompat.from(c).cancel(missedId(reminderId))
    }
}

package com.dailyduas.daily_duas

import android.content.Context

/** Alarm state machine shared by the receivers, the ring service and the method channel. */
object AlarmEngine {
    /** A main/test alarm that fires later than this (clock moved, device was off) does not ring. */
    private const val LATE_LIMIT_MS = 30 * 60_000L

    private const val STATUS_RINGING = "ringing"
    private const val STATUS_SNOOZED = "snoozed"
    private const val STATUS_MISSED = "missed"
    private const val STATUS_STARTED = "started"
    private const val STATUS_DISMISSED = "dismissed"

    fun ringEvent(kind: String): String = when (kind) {
        AlarmKind.NAG -> AlarmEventName.NAG_RANG
        AlarmKind.TEST -> AlarmEventName.TEST_RANG
        else -> AlarmEventName.RANG
    }

    /**
     * AlarmManager fired request code (reminderId, kind, weekday). Returns true when RingService was asked to
     * ring (it then releases the receiver's hand-off wake lock), false when nothing rings.
     */
    fun onFire(c: Context, reminderId: Int, kind: String, weekday: Int, extraTriggerAtMs: Long): Boolean {
        val code = AlarmScheduler.requestCode(reminderId, kind, weekday)
        val now = System.currentTimeMillis()
        val trigger = AlarmStore.scheduledEntry(c, code)?.triggerAtMs
            ?: extraTriggerAtMs.takeIf { it > 0 } ?: now
        val rem = AlarmStore.reminder(c, reminderId)

        if (kind == AlarmKind.MAIN) {
            if (rem == null || !rem.enabled || weekday !in rem.days) {
                AlarmScheduler.cancel(c, code)
                return false
            }
            // Schedule next week first so the chain never depends on this ring succeeding.
            val next = NextOccurrence.nextMs(rem.hour, rem.minute, weekday, maxOf(now, trigger) + 1_000L)
            AlarmScheduler.arm(c, reminderId, AlarmKind.MAIN, weekday, next)
        } else {
            AlarmScheduler.cancel(c, code) // one-shot
        }
        if (rem == null || (reminderId != TEST_REMINDER_ID && !rem.enabled)) return false
        if (now - trigger > LATE_LIMIT_MS) return false

        val previous = AlarmStore.occurrence(c, reminderId)
        val occurrence = when (kind) {
            AlarmKind.MAIN, AlarmKind.TEST -> {
                // A new occurrence supersedes the previous one's snooze/nag chain and missed notice.
                AlarmScheduler.cancel(c, reminderId, AlarmKind.SNOOZE)
                AlarmScheduler.cancel(c, reminderId, AlarmKind.NAG)
                Notifications.cancelMissed(c, reminderId)
                Occurrence(reminderId, trigger, 0, 0, STATUS_RINGING, rem.label, rem.routineId)
            }
            else -> {
                if (previous != null && previous.status in setOf(STATUS_STARTED, STATUS_DISMISSED)) return false
                (previous ?: Occurrence(reminderId, trigger, 0, 0, STATUS_RINGING, rem.label, rem.routineId))
                    .copy(status = STATUS_RINGING)
            }
        }
        AlarmStore.putOccurrence(c, occurrence)
        val ring = Ring(
            reminderId = reminderId,
            occurrenceMs = occurrence.occurrenceMs,
            routineId = rem.routineId,
            routineName = rem.routineName,
            label = rem.label,
            kind = kind,
            snoozesUsed = occurrence.snoozesUsed,
            maxSnoozes = rem.maxSnoozes,
            snoozeMinutes = rem.snoozeMinutes,
            startedMs = now,
            ringSeconds = rem.ringSeconds,
            vibrate = rem.vibrate,
            sound = rem.sound,
        )
        if (!RingService.start(c, ring)) {
            // Foreground service start refused: record the ring and fall back to the missed path.
            AlarmStore.logEvent(c, ring.reminderId, ring.occurrenceMs, ringEvent(kind), ring.label)
            onMissed(c, ring)
            return false
        }
        return true
    }

    /** Ringing ended without an answer (timeout, "stop", swipe, superseded or FGS refused). */
    fun onMissed(c: Context, r: Ring) {
        AlarmStore.logEvent(c, r.reminderId, r.occurrenceMs, AlarmEventName.AUTO_STOPPED, r.label)
        val rem = AlarmStore.reminder(c, r.reminderId)
        val stored = AlarmStore.occurrence(c, r.reminderId)
        // Replaced by a newer occurrence of the same reminder: leave its state and snooze/nag chain alone.
        if (stored != null && stored.occurrenceMs > r.occurrenceMs) return
        val occ = stored?.takeIf { it.occurrenceMs == r.occurrenceMs }
            ?: Occurrence(r.reminderId, r.occurrenceMs, r.snoozesUsed, 0, STATUS_MISSED, r.label, r.routineId)
        var nags = occ.nagsUsed
        if (rem != null && r.reminderId != TEST_REMINDER_ID && rem.enabled && rem.nagEnabled && nags < rem.nagMaxTimes) {
            nags += 1
            AlarmScheduler.arm(
                c, r.reminderId, AlarmKind.NAG, 0, System.currentTimeMillis() + rem.nagEveryMinutes * 60_000L,
            )
        }
        AlarmStore.putOccurrence(c, occ.copy(status = STATUS_MISSED, nagsUsed = nags))
        Notifications.postMissed(c, r)
    }

    /** start | snooze | dismiss | stop. Returns the snoozes left for the occurrence. */
    fun perform(c: Context, action: String, reminderId: Int, occurrenceMs: Long): Int {
        val service = RingService.current
        val ringing = service?.currentRing?.takeIf { it.reminderId == reminderId }
        val rem = AlarmStore.reminder(c, reminderId)
        val stored = AlarmStore.occurrence(c, reminderId)
        val occMs = when {
            occurrenceMs > 0 -> occurrenceMs
            ringing != null -> ringing.occurrenceMs
            else -> stored?.occurrenceMs ?: 0L
        }
        val isCurrent = stored == null || stored.occurrenceMs <= occMs
        val occ = stored?.takeIf { it.occurrenceMs == occMs } ?: Occurrence(
            reminderId, occMs, ringing?.snoozesUsed ?: 0, 0, STATUS_RINGING,
            ringing?.label ?: rem?.label ?: "", rem?.routineId,
        )
        val label = occ.label.ifEmpty { rem?.label ?: "" }
        val maxSnoozes = rem?.maxSnoozes ?: ringing?.maxSnoozes ?: 0
        fun left(used: Int) = (maxSnoozes - used).coerceAtLeast(0)

        when (action) {
            "start", "dismiss" -> {
                val status = if (action == "start") STATUS_STARTED else STATUS_DISMISSED
                val event = if (action == "start") AlarmEventName.STARTED else AlarmEventName.DISMISSED
                if (ringing != null) service.finish(status)
                Notifications.cancelMissed(c, reminderId)
                if (isCurrent) {
                    AlarmScheduler.cancel(c, reminderId, AlarmKind.SNOOZE)
                    AlarmScheduler.cancel(c, reminderId, AlarmKind.NAG)
                }
                if (occ.status != status) {
                    AlarmStore.logEvent(c, reminderId, occMs, event, label)
                    if (isCurrent) AlarmStore.putOccurrence(c, occ.copy(status = status))
                }
                return left(occ.snoozesUsed)
            }
            "snooze" -> {
                // Already snoozed (or answered) and not ringing, e.g. a second tap from a ring screen that missed
                // the notification's snooze: keep the armed snooze and the snooze count as they are.
                if (ringing == null && stored != null && stored.occurrenceMs == occMs &&
                    stored.status in setOf(STATUS_SNOOZED, STATUS_STARTED, STATUS_DISMISSED)
                ) {
                    return left(stored.snoozesUsed)
                }
                if (rem == null || occ.snoozesUsed >= maxSnoozes) return 0
                val used = occ.snoozesUsed + 1
                if (ringing != null) service.finish(STATUS_SNOOZED)
                Notifications.cancelMissed(c, reminderId)
                AlarmScheduler.cancel(c, reminderId, AlarmKind.NAG)
                AlarmScheduler.arm(
                    c, reminderId, AlarmKind.SNOOZE, 0, System.currentTimeMillis() + rem.snoozeMinutes * 60_000L,
                )
                AlarmStore.putOccurrence(c, occ.copy(snoozesUsed = used, status = STATUS_SNOOZED))
                AlarmStore.logEvent(c, reminderId, occMs, AlarmEventName.SNOOZED, label)
                return left(used)
            }
            "stop" -> {
                if (ringing != null) service.timeoutNow(RingService.REASON_STOPPED)
                return left(occ.snoozesUsed)
            }
            else -> return left(occ.snoozesUsed)
        }
    }

    /** Arms the test alarm (reminder id -1) that behaves exactly like a real one. Returns trigger ms. */
    fun scheduleTest(c: Context, seconds: Int, label: String, routineId: Int?): Long {
        AlarmStore.setTestReminder(
            c,
            NativeReminder(
                id = TEST_REMINDER_ID, label = label, hour = 0, minute = 0, weekdays = emptyList(), enabled = true,
                routineId = routineId, routineName = "", snoozeMinutes = 5, maxSnoozes = 3, nagEnabled = false,
                nagEveryMinutes = 10, nagMaxTimes = 0, ringSeconds = 120, vibrate = true, sound = "default",
            ),
        )
        for (kind in listOf(AlarmKind.TEST, AlarmKind.SNOOZE, AlarmKind.NAG)) {
            AlarmScheduler.cancel(c, TEST_REMINDER_ID, kind)
        }
        val at = System.currentTimeMillis() + seconds * 1_000L
        AlarmScheduler.arm(c, TEST_REMINDER_ID, AlarmKind.TEST, 0, at)
        return at
    }
}

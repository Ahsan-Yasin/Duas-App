package com.dailyduas.daily_duas

import org.json.JSONArray
import org.json.JSONObject

/** Kinds of scheduled alarms (ARCHITECTURE.md section 7). */
object AlarmKind {
    const val MAIN = "main"
    const val SNOOZE = "snooze"
    const val NAG = "nag"
    const val TEST = "test"
}

/** Event names logged for Dart (AlarmEvent.event). */
object AlarmEventName {
    const val RANG = "rang"
    const val AUTO_STOPPED = "auto_stopped"
    const val SNOOZED = "snoozed"
    const val DISMISSED = "dismissed"
    const val STARTED = "started"
    const val NAG_RANG = "nag_rang"
    const val TEST_RANG = "test_rang"
}

const val TEST_REMINDER_ID = -1

internal fun JSONObject.optIntOrNull(key: String): Int? =
    if (!has(key) || isNull(key)) null else (opt(key) as? Number)?.toInt()

/** A reminder dict as pushed by Dart (`Reminder.toNativeJson`). */
data class NativeReminder(
    val id: Int,
    val label: String,
    val hour: Int,
    val minute: Int,
    val weekdays: List<Int>,
    val enabled: Boolean,
    val routineId: Int?,
    val routineName: String,
    val snoozeMinutes: Int,
    val maxSnoozes: Int,
    val nagEnabled: Boolean,
    val nagEveryMinutes: Int,
    val nagMaxTimes: Int,
    val ringSeconds: Int,
    val vibrate: Boolean,
    val sound: String,
) {
    /** Valid ISO weekdays (Mon=1..Sun=7) without duplicates. */
    val days: List<Int> get() = weekdays.filter { it in 1..7 }.distinct()

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id); put("label", label); put("hour", hour); put("minute", minute)
        put("weekdays", JSONArray(weekdays)); put("enabled", enabled)
        put("routine_id", routineId ?: JSONObject.NULL); put("routine_name", routineName)
        put("snooze_minutes", snoozeMinutes); put("max_snoozes", maxSnoozes)
        put("nag_enabled", nagEnabled); put("nag_every_minutes", nagEveryMinutes); put("nag_max_times", nagMaxTimes)
        put("ring_seconds", ringSeconds); put("vibrate", vibrate); put("sound", sound)
    }

    companion object {
        fun fromJson(o: JSONObject): NativeReminder? {
            val id = o.optIntOrNull("id") ?: return null
            val days = mutableListOf<Int>()
            o.optJSONArray("weekdays")?.let { arr -> for (i in 0 until arr.length()) days += arr.optInt(i) }
            return NativeReminder(
                id = id,
                label = o.optString("label", "Daily duas"),
                hour = o.optInt("hour", 7).coerceIn(0, 23),
                minute = o.optInt("minute", 0).coerceIn(0, 59),
                weekdays = days,
                enabled = o.optBoolean("enabled", true),
                routineId = o.optIntOrNull("routine_id"),
                routineName = o.optString("routine_name", ""),
                snoozeMinutes = o.optInt("snooze_minutes", 5).coerceIn(1, 120),
                maxSnoozes = o.optInt("max_snoozes", 3).coerceIn(0, 20),
                nagEnabled = o.optBoolean("nag_enabled", true),
                nagEveryMinutes = o.optInt("nag_every_minutes", 10).coerceIn(1, 240),
                nagMaxTimes = o.optInt("nag_max_times", 3).coerceIn(0, 20),
                ringSeconds = o.optInt("ring_seconds", 120).coerceIn(10, 1800),
                vibrate = o.optBoolean("vibrate", true),
                sound = o.optString("sound", "default"),
            )
        }
    }
}

/** One alarm known to AlarmManager, mirrored in the store. weekday = 0 for snooze/nag/test. */
data class ScheduledEntry(
    val code: Int,
    val reminderId: Int,
    val weekday: Int,
    val kind: String,
    val triggerAtMs: Long,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("code", code); put("reminder_id", reminderId); put("weekday", weekday)
        put("kind", kind); put("trigger_at_ms", triggerAtMs)
    }

    fun toMap(exists: Boolean): Map<String, Any?> = mapOf(
        "reminder_id" to reminderId, "weekday" to weekday, "kind" to kind,
        "trigger_at_ms" to triggerAtMs, "exists" to exists,
    )

    companion object {
        fun fromJson(o: JSONObject) = ScheduledEntry(
            code = o.optInt("code"), reminderId = o.optInt("reminder_id"), weekday = o.optInt("weekday"),
            kind = o.optString("kind", AlarmKind.MAIN), triggerAtMs = o.optLong("trigger_at_ms"),
        )
    }
}

/** State of the current occurrence of one reminder (snooze/nag counters). */
data class Occurrence(
    val reminderId: Int,
    val occurrenceMs: Long,
    val snoozesUsed: Int,
    val nagsUsed: Int,
    val status: String, // ringing | snoozed | missed | started | dismissed
    val label: String,
    val routineId: Int?,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("reminder_id", reminderId); put("occurrence_ms", occurrenceMs); put("snoozes_used", snoozesUsed)
        put("nags_used", nagsUsed); put("status", status); put("label", label)
        put("routine_id", routineId ?: JSONObject.NULL)
    }

    companion object {
        fun fromJson(o: JSONObject) = Occurrence(
            reminderId = o.optInt("reminder_id"), occurrenceMs = o.optLong("occurrence_ms"),
            snoozesUsed = o.optInt("snoozes_used"), nagsUsed = o.optInt("nags_used"),
            status = o.optString("status", "ringing"), label = o.optString("label", ""),
            routineId = o.optIntOrNull("routine_id"),
        )
    }
}

/** A ringing alarm. toMap() is the Dart `RingingAlarm` dict; the extra fields drive the service. */
data class Ring(
    val reminderId: Int,
    val occurrenceMs: Long,
    val routineId: Int?,
    val routineName: String,
    val label: String,
    val kind: String,
    val snoozesUsed: Int,
    val maxSnoozes: Int,
    val snoozeMinutes: Int,
    val startedMs: Long,
    val ringSeconds: Int,
    val vibrate: Boolean,
    val sound: String,
) {
    val snoozesLeft: Int get() = (maxSnoozes - snoozesUsed).coerceAtLeast(0)

    fun toMap(): Map<String, Any?> = mapOf(
        "reminder_id" to reminderId, "occurrence_ms" to occurrenceMs, "routine_id" to routineId,
        "label" to label, "kind" to kind, "snoozes_used" to snoozesUsed, "max_snoozes" to maxSnoozes,
        "started_ms" to startedMs,
    )

    fun launchMap(action: String): Map<String, Any?> = mapOf(
        "action" to action, "reminder_id" to reminderId, "occurrence_ms" to occurrenceMs,
        "routine_id" to routineId, "label" to label, "kind" to kind,
    )

    fun toJson(): JSONObject = JSONObject().apply {
        put("reminder_id", reminderId); put("occurrence_ms", occurrenceMs)
        put("routine_id", routineId ?: JSONObject.NULL); put("routine_name", routineName)
        put("label", label); put("kind", kind); put("snoozes_used", snoozesUsed); put("max_snoozes", maxSnoozes)
        put("snooze_minutes", snoozeMinutes); put("started_ms", startedMs); put("ring_seconds", ringSeconds)
        put("vibrate", vibrate); put("sound", sound)
    }

    companion object {
        fun fromJson(o: JSONObject) = Ring(
            reminderId = o.optInt("reminder_id"), occurrenceMs = o.optLong("occurrence_ms"),
            routineId = o.optIntOrNull("routine_id"), routineName = o.optString("routine_name", ""),
            label = o.optString("label", ""), kind = o.optString("kind", AlarmKind.MAIN),
            snoozesUsed = o.optInt("snoozes_used"), maxSnoozes = o.optInt("max_snoozes"),
            snoozeMinutes = o.optInt("snooze_minutes", 5), startedMs = o.optLong("started_ms"),
            ringSeconds = o.optInt("ring_seconds", 120), vibrate = o.optBoolean("vibrate", true),
            sound = o.optString("sound", "default"),
        )

        fun parse(json: String?): Ring? = try {
            json?.let { fromJson(JSONObject(it)) }
        } catch (_: Exception) {
            null
        }
    }
}

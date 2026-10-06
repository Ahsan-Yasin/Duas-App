package com.dailyduas.daily_duas

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import androidx.core.os.UserManagerCompat
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

/**
 * Durable alarm state: device-protected SharedPreferences holding JSON strings (org.json, no extra dependency).
 * Keys: reminders, scheduled (code -> entry), occ_<id>, test (test reminder config), launch (mailbox),
 * events (log capped at [MAX_EVENTS]). All callers run on the main thread; writes use commit() so the
 * state survives a process death right after a receiver returns.
 */
@SuppressLint("ApplySharedPref")
object AlarmStore {
    private const val PREFS = "daily_duas_alarms"
    private const val K_REMINDERS = "reminders"
    private const val K_SCHEDULED = "scheduled"
    private const val K_OCC = "occ_"
    private const val K_TEST = "test"
    private const val K_LAUNCH = "launch"
    private const val K_EVENTS = "events"
    const val MAX_EVENTS = 500

    /** Device-protected flag file recording that [PREFS] was moved out of credential storage. */
    private const val META = "daily_duas_alarms_meta"
    private const val K_MOVED = "moved_to_device_storage"

    /** A launch Dart has not picked up within this time is dropped (never replayed on a later start). */
    private const val LAUNCH_TTL_MS = 15 * 60_000L

    @Volatile
    private var deviceContext: Context? = null

    @Volatile
    private var migrated = false

    /**
     * Device-protected (direct boot) storage, so BootReceiver/AlarmReceiver/RingService work after a reboot
     * before the first unlock. Older installs kept the file in credential storage: it is moved once, on the
     * first access while the user is unlocked (app update, BOOT_COMPLETED or the app's own sync).
     */
    private fun prefs(c: Context): SharedPreferences {
        val app = c.applicationContext
        val dp = deviceContext ?: app.createDeviceProtectedStorageContext().also { deviceContext = it }
        if (!migrated) {
            synchronized(this) {
                if (!migrated && UserManagerCompat.isUserUnlocked(app)) {
                    val meta = dp.getSharedPreferences(META, Context.MODE_PRIVATE)
                    if (!meta.getBoolean(K_MOVED, false)) {
                        // Move failed (I/O): keep using credential storage for now and retry on the next access.
                        if (!dp.moveSharedPreferencesFrom(app, PREFS)) {
                            return app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        }
                        meta.edit().putBoolean(K_MOVED, true).commit()
                    }
                    migrated = true
                }
            }
        }
        return dp.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    private fun obj(c: Context, key: String): JSONObject? =
        prefs(c).getString(key, null)?.let { runCatching { JSONObject(it) }.getOrNull() }

    private fun arr(c: Context, key: String): JSONArray =
        prefs(c).getString(key, null)?.let { runCatching { JSONArray(it) }.getOrNull() } ?: JSONArray()

    // ---- reminders -------------------------------------------------------------------------

    @Synchronized
    fun setReminders(c: Context, list: List<NativeReminder>) {
        val a = JSONArray()
        list.forEach { a.put(it.toJson()) }
        prefs(c).edit().putString(K_REMINDERS, a.toString()).commit()
    }

    @Synchronized
    fun reminders(c: Context): List<NativeReminder> {
        val a = arr(c, K_REMINDERS)
        return (0 until a.length()).mapNotNull { a.optJSONObject(it)?.let(NativeReminder::fromJson) }
    }

    /** The reminder config for [id]; [TEST_REMINDER_ID] returns the test alarm config. */
    fun reminder(c: Context, id: Int): NativeReminder? =
        if (id == TEST_REMINDER_ID) testReminder(c) else reminders(c).firstOrNull { it.id == id }

    @Synchronized
    fun setTestReminder(c: Context, r: NativeReminder) {
        prefs(c).edit().putString(K_TEST, r.toJson().toString()).commit()
    }

    fun testReminder(c: Context): NativeReminder? = obj(c, K_TEST)?.let(NativeReminder::fromJson)

    // ---- scheduled alarms ------------------------------------------------------------------

    @Synchronized
    fun scheduled(c: Context): List<ScheduledEntry> {
        val o = obj(c, K_SCHEDULED) ?: return emptyList()
        return o.keys().asSequence().mapNotNull { k -> o.optJSONObject(k)?.let(ScheduledEntry::fromJson) }.toList()
    }

    fun scheduledEntry(c: Context, code: Int): ScheduledEntry? =
        obj(c, K_SCHEDULED)?.optJSONObject(code.toString())?.let(ScheduledEntry::fromJson)

    @Synchronized
    fun putScheduled(c: Context, e: ScheduledEntry) {
        val o = obj(c, K_SCHEDULED) ?: JSONObject()
        o.put(e.code.toString(), e.toJson())
        prefs(c).edit().putString(K_SCHEDULED, o.toString()).commit()
    }

    @Synchronized
    fun removeScheduled(c: Context, code: Int) {
        val o = obj(c, K_SCHEDULED) ?: return
        if (o.remove(code.toString()) != null) prefs(c).edit().putString(K_SCHEDULED, o.toString()).commit()
    }

    // ---- occurrence state ------------------------------------------------------------------

    fun occurrence(c: Context, reminderId: Int): Occurrence? =
        obj(c, K_OCC + reminderId)?.let(Occurrence::fromJson)

    @Synchronized
    fun putOccurrence(c: Context, o: Occurrence) {
        prefs(c).edit().putString(K_OCC + o.reminderId, o.toJson().toString()).commit()
    }

    // ---- launch mailbox --------------------------------------------------------------------

    @Synchronized
    fun setLaunch(c: Context, launch: Map<String, Any?>?) {
        val e = prefs(c).edit()
        if (launch == null) {
            e.remove(K_LAUNCH)
        } else {
            e.putString(K_LAUNCH, JSONObject(launch).put("created_ms", System.currentTimeMillis()).toString())
        }
        e.commit()
    }

    /**
     * Reads and clears the pending launch action. Returns null for an entry older than [LAUNCH_TTL_MS] and for
     * a 'ring' launch whose occurrence is no longer ringing, so a launch Dart never consumed (process killed,
     * engine never listened) does not replay later as a phantom ring screen or recitation.
     */
    @Synchronized
    fun takeLaunch(c: Context): Map<String, Any?>? {
        val o = obj(c, K_LAUNCH) ?: return null
        prefs(c).edit().remove(K_LAUNCH).commit()
        val createdMs = o.optLong("created_ms", 0L)
        if (abs(System.currentTimeMillis() - createdMs) > LAUNCH_TTL_MS) return null
        val action = o.optString("action")
        val reminderId = o.optInt("reminder_id")
        val occurrenceMs = o.optLong("occurrence_ms")
        if (action == MainActivity.LAUNCH_RING) {
            val ring = RingService.ringing()
            if (ring == null || ring.reminderId != reminderId || ring.occurrenceMs != occurrenceMs) return null
        }
        return mapOf(
            "action" to action,
            "reminder_id" to reminderId,
            "occurrence_ms" to occurrenceMs,
            "routine_id" to o.optIntOrNull("routine_id"),
            "label" to o.optString("label"),
            "kind" to o.optString("kind", AlarmKind.MAIN),
            "created_ms" to createdMs,
        )
    }

    // ---- event log -------------------------------------------------------------------------

    @Synchronized
    fun logEvent(c: Context, reminderId: Int, occurrenceMs: Long, event: String, label: String) {
        val a = arr(c, K_EVENTS)
        a.put(JSONObject().apply {
            put("reminder_id", reminderId); put("occurrence_ms", occurrenceMs); put("event", event)
            put("at_ms", System.currentTimeMillis()); put("label", label)
        })
        val trimmed = if (a.length() > MAX_EVENTS) {
            JSONArray().also { t -> for (i in a.length() - MAX_EVENTS until a.length()) t.put(a.get(i)) }
        } else a
        prefs(c).edit().putString(K_EVENTS, trimmed.toString()).commit()
    }

    fun events(c: Context, sinceMs: Long): List<Map<String, Any?>> {
        val a = arr(c, K_EVENTS)
        return (0 until a.length()).mapNotNull { i ->
            val o = a.optJSONObject(i) ?: return@mapNotNull null
            if (o.optLong("at_ms") < sinceMs) return@mapNotNull null
            mapOf(
                "reminder_id" to o.optInt("reminder_id"), "occurrence_ms" to o.optLong("occurrence_ms"),
                "event" to o.optString("event"), "at_ms" to o.optLong("at_ms"), "label" to o.optString("label"),
            )
        }
    }
}

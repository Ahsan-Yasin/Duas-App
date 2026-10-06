package com.dailyduas.daily_duas

import android.content.Context
import android.os.PowerManager

/**
 * Hand-off wake lock between AlarmReceiver and RingService. AlarmManager holds its own lock only while
 * onReceive runs, and RingService's onStartCommand (where the ring wake lock is taken) runs later, so the CPU
 * could suspend in between. AlarmReceiver acquires this before starting the service; it is released when the
 * receiver does not start a ring, or once RingService has handled the start. Pending hand-offs are counted so
 * one ring cannot release another's; the timeout covers any missed release.
 */
object WakeLocks {
    private const val HANDOFF_TIMEOUT_MS = 60_000L
    private var handoff: PowerManager.WakeLock? = null
    private var pending = 0

    @Synchronized
    fun acquireHandoff(c: Context) {
        val wl = handoff ?: c.applicationContext.getSystemService(PowerManager::class.java)
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DailyDuas:handoff")
            ?.apply { setReferenceCounted(false) }
            ?.also { handoff = it }
            ?: return
        if (!wl.isHeld) pending = 0 // timed out: nothing is protected any more
        pending += 1
        runCatching { wl.acquire(HANDOFF_TIMEOUT_MS) }
    }

    @Synchronized
    fun releaseHandoff() {
        if (pending > 0) pending -= 1
        if (pending > 0) return
        handoff?.let { if (it.isHeld) runCatching { it.release() } }
    }
}

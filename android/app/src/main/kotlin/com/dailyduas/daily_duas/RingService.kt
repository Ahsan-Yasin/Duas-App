package com.dailyduas.daily_duas

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.io.File

/**
 * Foreground service that rings: looping alarm tone on USAGE_ALARM, vibration, partial wake lock and the
 * full-screen notification. Type systemExempted on API 34+ (allowed because the app holds
 * USE_EXACT_ALARM/SCHEDULE_EXACT_ALARM; unlike mediaPlayback it is not blocked from BOOT_COMPLETED on
 * Android 15 and needs no Play FGS declaration); mediaPlayback on API 29-33 where systemExempted does not
 * exist. Auto-stops after ring_seconds -> missed notification + nag.
 */
class RingService : Service() {
    companion object {
        private const val TAG = "DailyDuasRing"
        const val ACTION_RING = "com.dailyduas.daily_duas.RING"
        const val EXTRA_RING = "ring"
        private const val START_VOLUME = 0.3f
        private const val FADE_STEP = 0.05f

        /** 'stopped' event reasons besides the AlarmEventName ones (auto_stopped, snoozed, dismissed, started). */
        const val REASON_STOPPED = "stopped" // stop action / notification swiped away (missed + nag)
        const val REASON_REPLACED = "replaced" // another alarm started ringing (missed + nag)

        @Volatile
        var current: RingService? = null
            private set

        fun ringing(): Ring? = current?.currentRing

        fun start(c: Context, ring: Ring): Boolean = try {
            ContextCompat.startForegroundService(
                c,
                Intent(c, RingService::class.java).setAction(ACTION_RING).putExtra(EXTRA_RING, ring.toJson().toString()),
            )
            true
        } catch (e: Exception) { // ForegroundServiceStartNotAllowedException is an IllegalStateException
            Log.w(TAG, "Could not start ring service", e)
            false
        }
    }

    var currentRing: Ring? = null
        private set
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var focusRequest: AudioFocusRequest? = null
    private var volume = START_VOLUME
    /** Latest delivered start; stopSelfResult(lastStartId) keeps the service for a start still queued. */
    private var lastStartId = 0
    /** Foreground notification id; alternates per superseding ring so the new one alerts and fires its FSI. */
    private var notifId = Notifications.ID_RINGING
    private val handler = Handler(Looper.getMainLooper())
    private val timeoutRunnable = Runnable { timeoutNow() }
    private val fadeRunnable = object : Runnable {
        override fun run() {
            val p = player ?: return
            volume = (volume + FADE_STEP).coerceAtMost(1f)
            runCatching { p.setVolume(volume, volume) }
            if (volume < 1f) handler.postDelayed(this, 1_000L)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        current = this
        Notifications.ensureChannels(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        try {
            handleStart(intent)
        } finally {
            // Every ACTION_RING start comes from AlarmReceiver: the ring (if any) now holds its own wake lock.
            if (intent?.action == ACTION_RING) WakeLocks.releaseHandoff()
        }
        return START_NOT_STICKY // a restarted service would have no alarm context
    }

    private fun handleStart(intent: Intent?) {
        val ring = if (intent?.action == ACTION_RING) Ring.parse(intent.getStringExtra(EXTRA_RING)) else null
        if (ring == null) {
            // Honour the startForegroundService() contract even for an unexpected start, then go away.
            val active = currentRing
            if (active != null) {
                goForeground(active)
            } else {
                goForeground(null)
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelfResult(lastStartId)
            }
            return
        }
        // A ring already active: post the new one under the other id. startForeground with a new id removes
        // the old notification, and the new entry alerts and fires its full-screen intent (an in-place update
        // of the same id would do neither).
        val previousId = notifId
        if (currentRing != null) {
            notifId = if (notifId == Notifications.ID_RINGING) Notifications.ID_RINGING + 1 else Notifications.ID_RINGING
        }
        if (!goForeground(ring)) {
            notifId = previousId
            AlarmStore.logEvent(this, ring.reminderId, ring.occurrenceMs, AlarmEngine.ringEvent(ring.kind), ring.label)
            AlarmEngine.onMissed(applicationContext, ring)
            if (currentRing == null) stopSelfResult(lastStartId)
            return
        }
        currentRing?.let { previous ->
            // A second alarm while ringing: the first one ends as missed (+ nag). The activity keeps showing
            // over the keyguard for the new ring, so MainActivity.onRingStopped is not called here.
            stopOutputs()
            currentRing = null
            emitStopped(previous, REASON_REPLACED)
            AlarmEngine.onMissed(applicationContext, previous)
        }
        begin(ring)
    }

    private fun goForeground(ring: Ring?): Boolean {
        val notification = if (ring != null) Notifications.buildRinging(this, ring) else Notifications.buildPlaceholder(this)
        val types = mutableListOf<Int>()
        if (Build.VERSION.SDK_INT >= 34 && AlarmScheduler.canExact(this)) {
            types += ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED
        }
        types += if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0
        for (type in types) {
            try {
                ServiceCompat.startForeground(this, notifId, notification, type)
                return true
            } catch (e: Exception) {
                Log.w(TAG, "startForeground failed for type $type", e)
            }
        }
        return false
    }

    private fun begin(ring: Ring) {
        acquireWakeLock(ring.ringSeconds * 1_000L + 15_000L)
        currentRing = ring
        Notifications.cancelMissed(this, ring.reminderId)
        AlarmStore.logEvent(this, ring.reminderId, ring.occurrenceMs, AlarmEngine.ringEvent(ring.kind), ring.label)
        startAudio(ring.sound)
        if (ring.vibrate) startVibration()
        handler.postDelayed(timeoutRunnable, ring.ringSeconds * 1_000L)
        MainActivity.onRingStarted()
        // Sent for every ring, including snooze/nag re-rings of the same occurrence (new started_ms).
        NativeEvents.emit(HashMap(ring.toMap()).apply { put("type", "ringing") })
    }

    /** Stops ringing for [reason] (started | dismissed | snoozed | auto_stopped | stopped). */
    fun finish(reason: String) {
        val ring = currentRing ?: return
        currentRing = null
        stopOutputs()
        notifyStopped(ring, reason)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        // Not stopSelf(): that would also drop a ring start that is already queued behind this one.
        stopSelfResult(lastStartId)
    }

    /**
     * Ends the ring unanswered -> missed notice + nag. [reason] is auto_stopped (ring_seconds elapsed) or
     * stopped (stop action, notification swiped away).
     */
    fun timeoutNow(reason: String = AlarmEventName.AUTO_STOPPED) {
        val ring = currentRing ?: return
        finish(reason)
        AlarmEngine.onMissed(applicationContext, ring)
    }

    private fun notifyStopped(ring: Ring, reason: String) {
        emitStopped(ring, reason)
        MainActivity.onRingStopped(reason)
    }

    /** {"type":"stopped"} for every ring that ends, whatever the reason. */
    private fun emitStopped(ring: Ring, reason: String) {
        NativeEvents.emit(
            mapOf(
                "type" to "stopped", "reminder_id" to ring.reminderId, "occurrence_ms" to ring.occurrenceMs,
                "reason" to reason,
            ),
        )
    }

    private fun acquireWakeLock(timeoutMs: Long) {
        val pm = getSystemService(PowerManager::class.java) ?: return
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DailyDuas:ring").apply {
            setReferenceCounted(false)
            acquire(timeoutMs)
        }
    }

    private fun startAudio(sound: String) {
        if (sound == "silent" || sound == "none") return
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        getSystemService(AudioManager::class.java)?.let { am ->
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT).setAudioAttributes(attrs).build()
            focusRequest = request
            runCatching { am.requestAudioFocus(request) }
        }
        val p = createPlayer(attrs, sound) ?: if (sound != "default") createPlayer(attrs, "default") else null
        player = p ?: return
        volume = START_VOLUME
        runCatching {
            p.setVolume(volume, volume)
            p.start()
        }
        handler.postDelayed(fadeRunnable, 1_000L)
    }

    private fun createPlayer(attrs: AudioAttributes, sound: String): MediaPlayer? {
        val mp = MediaPlayer()
        return try {
            mp.setAudioAttributes(attrs) // must precede prepare()
            when {
                sound == "system" -> {
                    val uri = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
                        ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                    mp.setDataSource(this, uri)
                }
                sound != "default" && File(sound).isFile -> mp.setDataSource(sound)
                else -> resources.openRawResourceFd(R.raw.alarm_tone).use { afd ->
                    mp.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                }
            }
            mp.isLooping = true
            mp.prepare()
            mp
        } catch (e: Exception) {
            Log.w(TAG, "Could not play $sound", e)
            mp.release()
            null
        }
    }

    private fun startVibration() {
        val v: Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
            getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Vibrator::class.java)
        }
        if (v == null || !v.hasVibrator()) return
        val effect = VibrationEffect.createWaveform(longArrayOf(0, 700, 500, 700, 1_400), 0)
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(effect, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
            }
            vibrator = v
        } catch (e: Exception) {
            Log.w(TAG, "Vibration failed", e)
        }
    }

    private fun stopOutputs() {
        handler.removeCallbacks(timeoutRunnable)
        handler.removeCallbacks(fadeRunnable)
        player?.let { p ->
            runCatching { p.stop() }
            p.release()
        }
        player = null
        focusRequest?.let { req -> getSystemService(AudioManager::class.java)?.abandonAudioFocusRequest(req) }
        focusRequest = null
        vibrator?.cancel()
        vibrator = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onDestroy() {
        val ring = currentRing
        stopOutputs()
        currentRing = null
        if (ring != null) {
            // Torn down while ringing (not through finish): still report it and leave the missed notice + nag.
            notifyStopped(ring, AlarmEventName.AUTO_STOPPED)
            AlarmEngine.onMissed(applicationContext, ring)
        }
        if (current === this) current = null
        super.onDestroy()
    }
}

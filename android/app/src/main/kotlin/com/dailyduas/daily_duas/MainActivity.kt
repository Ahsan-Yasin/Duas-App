package com.dailyduas.daily_duas

import android.Manifest
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.time.ZoneId
import java.util.Locale

/**
 * Extends AudioServiceActivity (required by just_audio_background). Hosts the 'daily_duas/native'
 * MethodChannel and the 'daily_duas/native_events' EventChannel, and shows over the lock screen only
 * while launched for a ringing alarm.
 */
class MainActivity : AudioServiceActivity() {
    companion object {
        const val LAUNCH_RING = "ring"
        const val LAUNCH_START = "start"
        const val LAUNCH_OPEN = "open"
        private const val EXTRA_LAUNCH = "com.dailyduas.daily_duas.extra.LAUNCH"
        private const val EXTRA_RING = "com.dailyduas.daily_duas.extra.RING"
        private const val METHOD_CHANNEL = "daily_duas/native"
        private const val EVENT_CHANNEL = "daily_duas/native_events"
        private const val REQ_NOTIFICATIONS = 4711

        private var activityRef: WeakReference<MainActivity>? = null
        private var eventsEngine: WeakReference<FlutterEngine>? = null

        /** Explicit launch intent; the action string keeps PendingIntents for ring/start/open distinct. */
        fun launchIntent(c: Context, action: String, ring: Ring?): Intent =
            Intent(c, MainActivity::class.java)
                .setAction("com.dailyduas.daily_duas.LAUNCH_" + action.uppercase(Locale.ROOT))
                .putExtra(EXTRA_LAUNCH, action)
                .apply { if (ring != null) putExtra(EXTRA_RING, ring.toJson().toString()) }
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

        /**
         * Called by RingService when a ring starts: a live activity (e.g. still showing a previous ring that this
         * one replaced) shows over the keyguard again for it.
         */
        fun onRingStarted() {
            val a = activityRef?.get() ?: return
            a.runOnUiThread { if (!a.isFinishing && !a.isDestroyed) a.setShowOverLockScreen(true) }
        }

        /** Called by RingService when ringing ends: stop showing over the keyguard. */
        fun onRingStopped(reason: String) {
            val a = activityRef?.get() ?: return
            a.runOnUiThread {
                a.setShowOverLockScreen(false)
                if (reason == "started") a.requestUnlock()
            }
        }
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        val fresh = savedInstanceState == null &&
            (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0
        // Set lock-screen flags before the window is shown.
        if (fresh && intent.getStringExtra(EXTRA_LAUNCH) == LAUNCH_RING && RingService.ringing() != null) {
            setShowOverLockScreen(true)
        }
        super.onCreate(savedInstanceState)
        activityRef = WeakReference(this)
        Notifications.ensureChannels(this)
        if (fresh) handleLaunch(intent) else intent.removeExtra(EXTRA_LAUNCH)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleLaunch(intent)
    }

    override fun onDestroy() {
        pendingPermissionResult?.success(NotificationManagerCompat.from(this).areNotificationsEnabled())
        pendingPermissionResult = null
        if (activityRef?.get() === this) activityRef = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(::onMethodCall)
        // The engine is cached by audio_service and can outlive this activity: register the event
        // stream once per engine so an active Dart subscription keeps its sink.
        if (eventsEngine?.get() !== flutterEngine) {
            // A previous engine may have been destroyed by audio_service without Dart sending 'cancel': drop its
            // dead sink so hasListener is false until this engine's Dart listens (launches go to the mailbox).
            NativeEvents.onCancel(null)
            EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(NativeEvents)
            eventsEngine = WeakReference(flutterEngine)
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() = NativeEvents.onCancel(null)

                override fun onEngineWillDestroy() {
                    if (eventsEngine?.get() === flutterEngine) {
                        NativeEvents.onCancel(null)
                        eventsEngine = null
                    }
                }
            })
        }
    }

    private fun handleLaunch(intent: Intent?) {
        val action = intent?.getStringExtra(EXTRA_LAUNCH) ?: return
        val ring = Ring.parse(intent.getStringExtra(EXTRA_RING))
        intent.removeExtra(EXTRA_LAUNCH)
        intent.removeExtra(EXTRA_RING)
        if (ring == null) return // plain "open" from the status-bar alarm icon
        var effective = action
        when (action) {
            LAUNCH_RING -> if (RingService.ringing()?.reminderId == ring.reminderId) {
                setShowOverLockScreen(true)
            } else {
                effective = LAUNCH_OPEN // stale ringing notification; the ring is already over
            }
            LAUNCH_START -> AlarmEngine.perform(applicationContext, "start", ring.reminderId, ring.occurrenceMs)
        }
        val launch = ring.launchMap(effective)
        // hasListener means a live engine's Dart is subscribed (a destroyed engine's sink is dropped in
        // configureFlutterEngine / onEngineWillDestroy); otherwise the mailbox holds it (expires after 15 min).
        if (NativeEvents.hasListener) {
            NativeEvents.emit(HashMap(launch).apply { put("type", "launch") })
        } else {
            AlarmStore.setLaunch(applicationContext, launch) // Dart pulls it with get_launch_action
        }
    }

    private fun setShowOverLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
        if (on) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private fun requestUnlock() {
        val km = getSystemService(KeyguardManager::class.java) ?: return
        if (km.isKeyguardLocked) km.requestDismissKeyguard(this, null)
    }

    // ---- MethodChannel ---------------------------------------------------------------------

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val c = applicationContext
        try {
            when (call.method) {
                "sync_reminders" -> {
                    val raw = call.argument<List<Map<String, Any?>>>("reminders") ?: emptyList()
                    val list = raw.mapNotNull { NativeReminder.fromJson(JSONObject(it)) }
                    AlarmScheduler.sync(c, list)
                    result.success(AlarmScheduler.scheduledList(c))
                }
                "get_scheduled" -> result.success(AlarmScheduler.scheduledList(c))
                "schedule_test" -> {
                    val seconds = (call.argument<Number>("seconds")?.toInt() ?: 10).coerceIn(1, 3_600)
                    val label = call.argument<String>("label")?.takeIf { it.isNotBlank() }
                        ?: getString(R.string.alarm_default_title)
                    val routineId = call.argument<Number>("routine_id")?.toInt()
                    result.success(AlarmEngine.scheduleTest(c, seconds, label, routineId))
                }
                "get_launch_action" -> result.success(AlarmStore.takeLaunch(c))
                "get_ringing" -> result.success(RingService.ringing()?.toMap())
                "alarm_action" -> {
                    val action = call.argument<String>("action") ?: ""
                    val reminderId = call.argument<Number>("reminder_id")?.toInt()
                    if (reminderId == null) {
                        result.error("bad_args", "reminder_id is required", null)
                    } else {
                        val occ = call.argument<Number>("occurrence_ms")?.toLong() ?: 0L
                        result.success(AlarmEngine.perform(c, action, reminderId, occ))
                    }
                }
                "get_events" -> result.success(AlarmStore.events(c, call.argument<Number>("since_ms")?.toLong() ?: 0L))
                "get_status" -> result.success(status())
                "request_notification_permission" -> requestNotificationPermission(result)
                "open_settings" -> result.success(openSettings(call.argument<String>("page") ?: "app_details"))
                "get_timezone" -> result.success(ZoneId.systemDefault().id)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native_error", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun status(): Map<String, Any?> {
        val c = applicationContext
        val fullScreen = Build.VERSION.SDK_INT < 34 ||
            getSystemService(NotificationManager::class.java)?.canUseFullScreenIntent() != false
        val battery = getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(packageName) == true
        return mapOf(
            "notifications_enabled" to Notifications.alarmsVisible(c),
            "exact_alarms_allowed" to AlarmScheduler.canExact(c),
            "full_screen_allowed" to fullScreen,
            "ignoring_battery_optimizations" to battery,
            "next_alarm_ms" to AlarmScheduler.nextAlarmMs(c),
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "timezone" to ZoneId.systemDefault().id,
            "sdk_int" to Build.VERSION.SDK_INT,
            "is_android" to true,
        )
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        val granted = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted || isFinishing || isDestroyed) {
            result.success(NotificationManagerCompat.from(this).areNotificationsEnabled())
            return
        }
        pendingPermissionResult?.success(false)
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFICATIONS) {
            pendingPermissionResult?.success(NotificationManagerCompat.from(this).areNotificationsEnabled())
            pendingPermissionResult = null
        }
    }

    private fun openSettings(page: String): Boolean {
        val pkg = Uri.parse("package:$packageName")
        val appDetails = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg)
        val intent = when (page) {
            "exact_alarm" -> if (Build.VERSION.SDK_INT >= 31) {
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, pkg)
            } else appDetails
            "full_screen" -> if (Build.VERSION.SDK_INT >= 34) {
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, pkg)
            } else appDetails
            "battery_request" -> Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, pkg)
            "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            "notifications" -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            else -> appDetails
        }
        return tryStart(intent) || (intent !== appDetails && tryStart(appDetails))
    }

    private fun tryStart(intent: Intent): Boolean = try {
        startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }
}

package com.achyrio.vayu.transfer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps the process, CPU and Wi-Fi radio awake while a transfer is running.
 *
 * Without it Android freezes or dozes the app as soon as the screen turns off or the
 * user switches apps, which stalls the socket and makes long transfers time out.
 * The service owns its own Wi-Fi lock so discovery restarts cannot release it mid-transfer.
 */
class TransferForegroundService : Service() {
    companion object {
        private const val TAG = "Vayu.TransferService"
        private const val CHANNEL_ID = "vayu_transfers"
        private const val NOTIFICATION_ID = 4101
        const val ACTION_START = "com.achyrio.vayu.transfer.START"
        const val ACTION_UPDATE = "com.achyrio.vayu.transfer.UPDATE"
        const val ACTION_STOP = "com.achyrio.vayu.transfer.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"

        // Upper bound so a lost stop call cannot keep the CPU awake forever.
        private const val WAKE_LOCK_TIMEOUT_MS = 6L * 60L * 60L * 1000L
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLocks: List<WifiManager.WifiLock> = emptyList()
    private var inForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelfCleanly()
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Vayu"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Transferring files"
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
        showForeground(title, text, progress)
        if (inForeground) acquireLocks()
        // A killed service must not restart by itself: transfer state lives in Dart.
        return START_NOT_STICKY
    }

    private fun showForeground(title: String, text: String, progress: Int) {
        ensureChannel()
        val notification = buildNotification(title, text, progress)
        if (inForeground) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, notification)
            return
        }
        try {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            }
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
            inForeground = true
        } catch (e: Exception) {
            // Android 12+ refuses foreground starts from the background. The transfer
            // continues without the guarantee rather than crashing the app.
            Log.w(TAG, "Could not enter foreground: ${e.message}")
            stopSelf()
        }
    }

    private fun buildNotification(title: String, text: String, progress: Int) =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setContentIntent(launchIntent())
            .apply {
                if (progress in 0..100) {
                    setProgress(100, progress, false)
                } else {
                    setProgress(0, 0, true)
                }
            }
            .build()

    private fun launchIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launch.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "File transfers",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows progress while Vayu sends or receives files"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Vayu:transfer").apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_TIMEOUT_MS)
            }
        }
        if (wifiLocks.isNotEmpty()) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        val locks = mutableListOf<WifiManager.WifiLock>()
        // HIGH_PERF keeps the radio out of power save with the screen off.
        // LOW_LATENCY additionally lowers latency while the app is visible (API 29+).
        @Suppress("DEPRECATION")
        locks.add(wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Vayu:transfer"))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            locks.add(wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "Vayu:transfer-ll"))
        }
        locks.forEach {
            try {
                it.setReferenceCounted(false)
                it.acquire()
            } catch (e: Exception) {
                Log.w(TAG, "Wi-Fi lock acquire failed: ${e.message}")
            }
        }
        wifiLocks = locks
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {}
        wakeLock = null
        wifiLocks.forEach {
            try {
                if (it.isHeld) it.release()
            } catch (_: Exception) {}
        }
        wifiLocks = emptyList()
    }

    private fun stopSelfCleanly() {
        releaseLocks()
        if (inForeground) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            inForeground = false
        }
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15 data-sync time budget exhausted: give the resources back.
        Log.w(TAG, "Foreground service timeout reached; stopping")
        stopSelfCleanly()
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }
}

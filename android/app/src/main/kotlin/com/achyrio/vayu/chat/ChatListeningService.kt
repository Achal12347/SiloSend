package com.achyrio.vayu.chat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps Vayu running while it waits for chat messages with the screen off.
 *
 * Without a foreground service Android freezes a background app within
 * minutes, so nearby phones could no longer reach it. Messages themselves are
 * handled in Dart, in this same process: when the app's task is removed Dart
 * is gone, so the service stops too instead of claiming to listen.
 */
class ChatListeningService : Service() {
    companion object {
        private const val TAG = "Vayu.ChatListening"
        private const val CHANNEL_ID = "vayu_chat_listening"
        private const val NOTIFICATION_ID = 4103

        /** Android only allows this while the app is on screen; refusal is logged. */
        fun start(context: Context): Boolean = try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, ChatListeningService::class.java),
            )
            true
        } catch (e: Exception) {
            Log.w(TAG, "Not started: ${e.javaClass.simpleName}")
            false
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ChatListeningService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        try {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            } else {
                0
            }
            ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(), type)
        } catch (e: Exception) {
            Log.w(TAG, "Could not enter foreground: ${e.javaClass.simpleName}")
            stopSelf()
        }
        // Not restarted by itself: only a running app can receive messages.
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun buildNotification() =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Ready for nearby messages")
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openApp())
            .build()

    private fun openApp(): PendingIntent? {
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
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Waiting for messages",
                NotificationManager.IMPORTANCE_MIN,
            ).apply { setShowBadge(false) },
        )
    }
}

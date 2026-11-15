package com.jingyu.client_flutter

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder

object ShellNotifications {
    const val CONNECTION_CHANNEL = "jingyu_connection"
    const val CALL_CHANNEL = "jingyu_calls"
    fun allowed(context: Context): Boolean =
        (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
    fun channels(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) {
            context.getSystemService(NotificationManager::class.java).apply {
                createNotificationChannel(NotificationChannel(CONNECTION_CHANNEL, "连接保活", NotificationManager.IMPORTANCE_LOW))
                createNotificationChannel(NotificationChannel(CALL_CHANNEL, "来电与未接来电", NotificationManager.IMPORTANCE_HIGH))
            }
        }
    }
    fun builder(context: Context, channel: String): Notification.Builder {
        channels(context)
        return Notification.Builder(context, channel).setSmallIcon(android.R.drawable.sym_action_chat)
            .setContentIntent(PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            .setVisibility(Notification.VISIBILITY_PRIVATE)
    }
}

/** Keeps the Flutter engine's WebSocket eligible to run while the app is backgrounded. */
class KeepAliveService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(1001, ShellNotifications.builder(this, ShellNotifications.CONNECTION_CHANNEL)
            .setContentTitle("鲸言鲸语连接中")
            .setContentText("保持消息连接；系统限制下可能漏接")
            .setOngoing(true).build())
        return START_NOT_STICKY
    }
    override fun onBind(intent: Intent?): IBinder? = null
}

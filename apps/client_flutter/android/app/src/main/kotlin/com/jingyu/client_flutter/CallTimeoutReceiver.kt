package com.jingyu.client_flutter

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.security.MessageDigest

/** Persistent terminal states make replayed call_id frames harmless across process restarts. */
class CallTimeoutReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        intent.getStringExtra("callId")?.let { expire(context, it) }
    }

    companion object {
        private const val TIMEOUT = 30_000L
        private val handler = Handler(Looper.getMainLooper())
        private fun key(callId: String) = MessageDigest.getInstance("SHA-256")
            .digest(callId.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
        private fun prefs(context: Context) = context.getSharedPreferences("jingyu_calls", Context.MODE_PRIVATE)
        private fun alarm(context: Context, callId: String): PendingIntent = PendingIntent.getBroadcast(
            context, 0, Intent(context, CallTimeoutReceiver::class.java).apply {
                action = "com.jingyu.client_flutter.CALL_TIMEOUT"
                data = android.net.Uri.parse("jingyu://calls/${key(callId)}")
                putExtra("callId", callId)
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        @Synchronized
        fun update(context: Context, callId: String, callerName: String, state: String, hidePreview: Boolean) {
            require(callId.isNotBlank() && callId.length <= 512) { "Valid callId required" }
            require(state in setOf("ringing", "answered", "ended")) { "Unknown call state" }
            val preferences = prefs(context)
            val id = key(callId)
            val previous = preferences.getString("$id.state", null)
            if (previous in setOf("answered", "ended", "missed")) return
            val manager = context.getSystemService(NotificationManager::class.java)
            if (state != "ringing") {
                check(preferences.edit().putString("$id.state", state).commit())
                context.getSystemService(AlarmManager::class.java).cancel(alarm(context, callId))
                manager.cancel(id, 1002)
                return
            }
            if (previous == "ringing") return // A duplicate must never extend the deadline.
            val deadline = SystemClock.elapsedRealtime() + TIMEOUT
            check(preferences.edit().putString("$id.state", "ringing")
                .putString("$id.caller", callerName.take(120)).putBoolean("$id.private", hidePreview)
                .putLong("$id.deadline", deadline).commit())
            show(context, id, "来电 · 可能漏接", if (hidePreview) "打开鲸言鲸语查看来电" else "$callerName 正在呼叫", true)
            // Handler provides the 30s transition while alive. Inexact alarm is a process-death
            // fallback; ROM/doze restrictions may delay it, hence the explicit 可能漏接 copy.
            context.getSystemService(AlarmManager::class.java).setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + TIMEOUT, alarm(context, callId))
            handler.postDelayed({ expire(context.applicationContext, callId) }, TIMEOUT)
        }

        @Synchronized
        private fun expire(context: Context, callId: String) {
            val preferences = prefs(context)
            val id = key(callId)
            if (preferences.getString("$id.state", null) != "ringing") return
            val remaining = preferences.getLong("$id.deadline", 0) - SystemClock.elapsedRealtime()
            if (remaining > 0) {
                handler.postDelayed({ expire(context.applicationContext, callId) }, remaining)
                return
            }
            check(preferences.edit().putString("$id.state", "missed").commit())
            val body = if (preferences.getBoolean("$id.private", true)) "打开鲸言鲸语查看未接来电"
                else "${preferences.getString("$id.caller", "来电")} 的未接来电"
            show(context, id, "未接来电 · 可能漏接", body, false)
        }

        private fun show(context: Context, id: String, title: String, text: String, ringing: Boolean) {
            if (!ShellNotifications.allowed(context)) return
            val notification = ShellNotifications.builder(context, ShellNotifications.CALL_CHANNEL)
                .setContentTitle(title).setContentText(text)
                .setCategory(if (ringing) Notification.CATEGORY_CALL else Notification.CATEGORY_MISSED_CALL)
                .setOnlyAlertOnce(true).setAutoCancel(!ringing).setOngoing(ringing).build()
            context.getSystemService(NotificationManager::class.java).notify(id, 1002, notification)
        }
    }
}

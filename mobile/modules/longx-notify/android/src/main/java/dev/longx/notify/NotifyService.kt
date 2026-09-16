package dev.longx.notify

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.core.content.getSystemService
import org.json.JSONObject

/**
 * A foreground service holding the `notify` connection so the phone hears
 * about an approval waiting or a task done while the app is in the
 * background — no FCM. One notification per thread (a later event for
 * the same thread replaces it); tapping opens the thread in the app via
 * the `longx://` scheme.
 */
class NotifyService : Service(), NotifyClient.Listener {
    private var client: NotifyClient? = null
    private var socketUrl: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Prefs(this).clear()
            stopSelf()
            return START_NOT_STICKY
        }
        val url = Prefs(this).socketUrl
        if (url == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (client != null && socketUrl == url) return START_STICKY
        socketUrl = url
        channels()
        foreground(connected = false)
        client?.stop()
        client = NotifyClient(url, this).also { it.start() }
        return START_STICKY
    }

    override fun onDestroy() {
        client?.stop()
        client = null
        super.onDestroy()
    }

    override fun onState(connected: Boolean) = post(ID_SERVICE, serviceNotification(connected))

    override fun onRunning(running: List<JSONObject>) {
        for (thread in running) {
            if (!thread.optBoolean("waiting")) continue
            val id = thread.optString("id")
            val slug = thread.optString("project_slug")
            val title = thread.optString("title").ifEmpty { thread.optString("preview") }.ifEmpty { thread.optString("project_name") }
            show(kind = "approval", title = "等待审批", body = title, url = "/p/$slug/t/$id", threadId = id)
        }
    }

    override fun onEvent(event: JSONObject) {
        val url = event.optString("url").takeIf { it.isNotEmpty() } ?: return
        show(
            kind = event.optString("kind"),
            title = event.optString("title"),
            body = event.optString("body"),
            url = url,
            threadId = event.optString("thread_id").takeIf { it.isNotEmpty() },
        )
    }

    private fun show(kind: String, title: String, body: String, url: String, threadId: String?) {
        val urgent = kind == "approval"
        val open = Intent(Intent.ACTION_VIEW, Uri.parse("longx://$url"))
            .setPackage(packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val id = threadId?.hashCode() ?: url.hashCode()
        val pending = PendingIntent.getActivity(this, id, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(this, if (urgent) CHANNEL_URGENT else CHANNEL_EVENTS)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setPriority(if (urgent) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .build()
        post(id, notification)
    }

    private fun post(id: Int, notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        NotificationManagerCompat.from(this).notify(id, notification)
    }

    private fun channels() {
        val manager = getSystemService<NotificationManager>() ?: return
        manager.createNotificationChannel(NotificationChannel(CHANNEL_SERVICE, "连接状态", NotificationManager.IMPORTANCE_MIN))
        manager.createNotificationChannel(NotificationChannel(CHANNEL_EVENTS, "任务", NotificationManager.IMPORTANCE_DEFAULT))
        manager.createNotificationChannel(NotificationChannel(CHANNEL_URGENT, "等待你", NotificationManager.IMPORTANCE_HIGH))
    }

    private fun foreground(connected: Boolean) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, ID_SERVICE, serviceNotification(connected), type)
    }

    private fun serviceNotification(connected: Boolean): Notification {
        val host = runCatching { Uri.parse(socketUrl).host }.getOrNull() ?: ""
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val open = PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(
            this, 2, Intent(this, NotifyService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_SERVICE)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Longx")
            .setContentText(if (connected) "已连接 $host" else "正在连接 $host…")
            .setContentIntent(open)
            .addAction(0, "停止", stop)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()
    }

    companion object {
        private const val ID_SERVICE = 1
        private const val ACTION_STOP = "dev.longx.notify.STOP"
        const val CHANNEL_SERVICE = "longx_service"
        const val CHANNEL_EVENTS = "longx_events"
        const val CHANNEL_URGENT = "longx_urgent"

        /** starts (or re-points) the service when a server is remembered, stops it otherwise */
        fun sync(context: Context) {
            val intent = Intent(context, NotifyService::class.java)
            if (Prefs(context).socketUrl != null) {
                runCatching { context.startForegroundService(intent) }
            } else {
                context.stopService(intent)
            }
        }
    }
}

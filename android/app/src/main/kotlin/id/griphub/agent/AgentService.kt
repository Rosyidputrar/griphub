package id.griphub.agent

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the app process alive while the agent is working so a long run is not
 * killed when the user switches apps. The process itself lives in AgentRuntime.
 */
class AgentService : Service() {
    companion object {
        private const val ID = 1

        /**
         * Two independent reasons to keep the process alive. The old code
         * used one flag for both, so the chat ending switched the service
         * off while schedules were still relying on it. The service runs
         * while EITHER reason is active.
         */
        private var busy = false
        private var keepAlive = false
        private var keepAliveTitle: String? = null
        private var keepAliveText: String? = null
        private var stoppable = false

        /** The agent itself is working: the notification offers Stop. */
        fun setBusy(context: Context, on: Boolean) {
            busy = on
            stoppable = on
            syncService(context)
        }

        /** Queued runs and schedules need the process alive. */
        fun setKeepAlive(context: Context, on: Boolean, title: String? = null, text: String? = null) {
            keepAlive = on
            if (on) {
                keepAliveTitle = title
                keepAliveText = text
            }
            syncService(context)
        }

        private fun syncService(context: Context) {
            if (busy || keepAlive) {
                val intent = Intent(context, AgentService::class.java)
                if (!busy && keepAlive) {
                    intent.putExtra("title", keepAliveTitle)
                    intent.putExtra("text", keepAliveText)
                }
                context.startForegroundService(intent)
            } else {
                context.stopService(Intent(context, AgentService::class.java))
            }
        }

        /**
         * Refreshes the ongoing notification (current chat and tool). Posted straight to the notification manager:
         * starting the service again from the background is not allowed on Android 12+.
         */
        fun update(context: Context, title: String?, text: String?) {
            if (!busy && !keepAlive) return
            context.getSystemService(NotificationManager::class.java)
                .notify(ID, build(context, title, text, stoppable))
        }

        private fun build(context: Context, title: String?, text: String?, stoppable: Boolean): Notification {
            Notifications.ensureChannels(context)
            val builder = Notification.Builder(context, Notifications.ACTIVITY)
                .setSmallIcon(R.drawable.ic_stat_agent)
                .setContentTitle(title ?: "GripHub AI Agent")
                .setContentText(text ?: Notifications.t(context, "Agent is working", "Agent sedang bekerja"))
                .setContentIntent(Notifications.openIntent(context, 0, mapOf("action" to "open_chat")))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
            if (stoppable) {
                val stop = PendingIntent.getBroadcast(
                    context, 0, Intent(context, StopReceiver::class.java), PendingIntent.FLAG_IMMUTABLE,
                )
                builder.addAction(
                    Notification.Action.Builder(null, Notifications.t(context, "Stop", "Hentikan"), stop).build()
                )
            }
            return builder.build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = build(
            this,
            intent?.getStringExtra("title"),
            intent?.getStringExtra("text"),
            stoppable,
        )
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, notification)
        }
        return START_NOT_STICKY
    }
}

package io.github.dhkun.xzmupower

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

object AlertNotify {
    const val CHANNEL_ALERT = "balance_alert"
    const val CHANNEL_INFO = "balance_info"

    fun ensureChannels(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ALERT, "低电量告警", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "宿舍电量低于阈值时提醒" })
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_INFO, "状态通知", NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = "查询失败、会话失效等状态" })
    }

    private fun canNotify(ctx: Context) =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

    private fun pi(ctx: Context, intent: Intent) = PendingIntent.getActivity(
        ctx, intent.hashCode(), intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /** 低电量告警 */
    fun alert(ctx: Context, title: String, body: String) {
        ensureChannels(ctx)
        if (!canNotify(ctx)) return
        val intent = Intent(ctx, MainActivity::class.java)
        val n = NotificationCompat.Builder(ctx, CHANNEL_ALERT)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pi(ctx, intent))
            .setAutoCancel(true)
            .build()
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(1001, n)
    }

    /** 状态提醒(会话失效等) */
    fun info(ctx: Context, title: String, body: String, openSetup: Boolean = false) {
        ensureChannels(ctx)
        if (!canNotify(ctx)) return
        val intent = Intent(ctx, if (openSetup) SetupActivity::class.java else MainActivity::class.java)
        val n = NotificationCompat.Builder(ctx, CHANNEL_INFO)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pi(ctx, intent))
            .setAutoCancel(true)
            .build()
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(1002, n)
    }
}

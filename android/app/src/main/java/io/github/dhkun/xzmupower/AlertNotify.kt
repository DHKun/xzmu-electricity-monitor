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
    private const val ID_ALERT = 1001
    private const val ID_INFO = 1002
    private const val ID_LOGIN = 1003

    fun ensureChannels(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ALERT, "低电量告警", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "宿舍电量低于阈值时提醒" })
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_INFO, "状态通知", NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = "查询失败、需要重新登录等状态" })
    }

    private fun canNotify(ctx: Context) =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

    private fun pi(ctx: Context, intent: Intent) = PendingIntent.getActivity(
        ctx, intent.hashCode(), intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun post(ctx: Context, id: Int, channel: String, title: String, body: String, intent: Intent): Boolean {
        ensureChannels(ctx)
        if (!canNotify(ctx)) return false
        val n = NotificationCompat.Builder(ctx, channel)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pi(ctx, intent))
            .setAutoCancel(true)
            .build()
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(id, n)
        return true
    }

    /** 低电量告警 */
    fun alert(ctx: Context, title: String, body: String) {
        post(ctx, ID_ALERT, CHANNEL_ALERT, title, body, Intent(ctx, MainActivity::class.java))
    }

    /** 状态提醒 */
    fun info(ctx: Context, title: String, body: String) {
        post(ctx, ID_INFO, CHANNEL_INFO, title, body, Intent(ctx, MainActivity::class.java))
    }

    /** 需要用户手动登录; 返回是否已交给系统发布 */
    fun login(ctx: Context): Boolean = post(ctx, ID_LOGIN, CHANNEL_INFO,
        "电费监控: 需要重新登录", "自动登录未能完成, 点击重新登录后即可恢复监控",
        Intent(ctx, SetupActivity::class.java).putExtra(SetupActivity.EXTRA_REBIND, true))

    fun cancelLogin(ctx: Context) {
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(ID_LOGIN)
    }
}

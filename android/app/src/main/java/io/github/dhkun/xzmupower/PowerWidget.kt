package io.github.dhkun.xzmupower

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 桌面小组件: 默认 2×2, 拉宽到约 4×2 时切换为圆环布局; 刷新按钮在后台查询, 不打开 App */
class PowerWidget : AppWidgetProvider() {

    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        ids.forEach { update(ctx, mgr, it, busy = false) }
    }

    override fun onAppWidgetOptionsChanged(ctx: Context, mgr: AppWidgetManager, id: Int, options: Bundle) {
        update(ctx, mgr, id, busy = false)
    }

    override fun onReceive(ctx: Context, intent: Intent) {
        super.onReceive(ctx, intent)
        if (intent.action == ACTION_REFRESH && Prefs.configured(ctx)) {
            updateAll(ctx, busy = true)
            // 查询走 WorkManager, 完成后 PowerSync 会刷新所有小组件
            WorkManager.getInstance(ctx).enqueueUniqueWork(
                REFRESH_WORK, ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<QueryWorker>().build())
        }
    }

    companion object {
        private const val ACTION_REFRESH = "io.github.dhkun.xzmupower.WIDGET_REFRESH"
        private const val REFRESH_WORK = "widget_refresh"
        /** 宽度达到此值(dp)时用 4×2 圆环布局 */
        private const val WIDE_DP = 250

        fun updateAll(ctx: Context, busy: Boolean = false) {
            val mgr = AppWidgetManager.getInstance(ctx)
            mgr.getAppWidgetIds(ComponentName(ctx, PowerWidget::class.java))
                .forEach { update(ctx, mgr, it, busy) }
        }

        private fun update(ctx: Context, mgr: AppWidgetManager, id: Int, busy: Boolean) {
            val views = if (Build.VERSION.SDK_INT >= 31) {
                // Android 12+: 交给启动器按实际尺寸挑布局
                RemoteViews(mapOf(
                    SizeF(110f, 100f) to build(ctx, wide = false, busy = busy),
                    SizeF(WIDE_DP.toFloat(), 100f) to build(ctx, wide = true, busy = busy),
                ))
            } else {
                val minWidth = mgr.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
                build(ctx, wide = minWidth >= WIDE_DP, busy = busy)
            }
            mgr.updateAppWidget(id, views)
        }

        private fun build(ctx: Context, wide: Boolean, busy: Boolean): RemoteViews {
            val open = PendingIntent.getActivity(ctx, 0,
                Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val v = PowerStatus.load(ctx)
            if (!v.configured) {
                return RemoteViews(ctx.packageName, R.layout.widget_unbound).apply {
                    setOnClickPendingIntent(android.R.id.background, open)
                }
            }
            val refresh = PendingIntent.getBroadcast(ctx, 1,
                Intent(ctx, PowerWidget::class.java).setAction(ACTION_REFRESH),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val days = if (v.daysLeft >= 0) "约可用 ${v.daysLeft} 天" else v.level.text
            // 会话过期时状态行改为提示重新登录, 圆点变红
            val headline = if (v.sessionDead) "登录已过期" else v.level.text
            val sub = when {
                v.sessionDead && wide -> "点开 App 重新登录"
                v.sessionDead -> "登录已过期"
                else -> days
            }
            val dot = if (v.sessionDead) levelColor(ctx, PowerLevel.LOW) else levelColor(ctx, v.level)
            val time = if (v.lastAt > 0) SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(v.lastAt)) else ""

            return RemoteViews(ctx.packageName, if (wide) R.layout.widget_wide else R.layout.widget_small).apply {
                // 底色随电量, 与首页主卡一致
                setInt(android.R.id.background, "setBackgroundResource", when (v.level) {
                    PowerLevel.OK -> R.drawable.widget_bg
                    PowerLevel.WARN -> R.drawable.widget_bg_warn
                    PowerLevel.LOW -> R.drawable.widget_bg_low
                    PowerLevel.UNKNOWN -> R.drawable.widget_bg_none
                })
                setOnClickPendingIntent(android.R.id.background, open)
                setOnClickPendingIntent(R.id.wRefresh, refresh)
                setTextViewText(R.id.wRoom, v.room.ifBlank { "我的宿舍" })
                setTextViewText(R.id.wQty, PowerStatus.fmtQty(v.qty))
                setTextViewText(R.id.wSub, sub)
                setInt(R.id.wDot, "setColorFilter", dot)
                setViewVisibility(R.id.wRefreshIcon, if (busy) View.GONE else View.VISIBLE)
                setViewVisibility(R.id.wBusy, if (busy) View.VISIBLE else View.GONE)
                if (wide) {
                    setProgressBar(R.id.wRing, 100, v.percent, false)
                    setTextViewText(R.id.wLevel, headline)
                    setTextViewText(R.id.wTime, if (time.isNotEmpty()) "$time 更新" else "")
                } else {
                    setProgressBar(R.id.wBar, 100, v.percent, false)
                    setTextViewText(R.id.wTime, time)
                }
            }
        }

        private fun levelColor(ctx: Context, level: PowerLevel): Int = ContextCompat.getColor(ctx, when (level) {
            PowerLevel.OK -> R.color.level_ok
            PowerLevel.WARN -> R.color.level_warn
            PowerLevel.LOW -> R.color.m3_error_container
            PowerLevel.UNKNOWN -> R.color.widget_on_secondary
        })
    }
}

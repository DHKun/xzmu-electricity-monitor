package io.github.dhkun.xzmupower

import android.Manifest
import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.view.View
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.snackbar.Snackbar

/** 首页与设置页共用的操作 */
object Actions {
    private val THRESHOLDS = arrayOf(5f, 10f, 15f, 20f, 30f, 50f, 80f, 100f)

    fun pickThreshold(activity: Activity, done: () -> Unit) {
        val current = THRESHOLDS.indexOfFirst { it == Prefs.threshold(activity) }
        MaterialAlertDialogBuilder(activity)
            .setTitle("提醒阈值")
            .setSingleChoiceItems(THRESHOLDS.map { "${PowerStatus.fmtQty(it)} 度" }.toTypedArray(), current) { d, i ->
                Prefs.setThreshold(activity, THRESHOLDS[i])
                AlertEval.reevaluateWithLast(activity)
                PowerWidget.updateAll(activity)
                d.dismiss()
                done()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    /** 系统"添加小组件"对话框; 不支持的启动器提示手动添加 */
    fun pinWidget(activity: Activity, anchor: View) {
        val mgr = AppWidgetManager.getInstance(activity)
        if (mgr.isRequestPinAppWidgetSupported) {
            mgr.requestPinAppWidget(ComponentName(activity, PowerWidget::class.java), null, null)
        } else {
            Snackbar.make(anchor, "请长按桌面空白处 → 小组件, 找到民大电费", Snackbar.LENGTH_LONG).show()
        }
    }

    fun notificationsOn(ctx: Context): Boolean {
        val granted = Build.VERSION.SDK_INT < 33 ||
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        return granted && NotificationManagerCompat.from(ctx).areNotificationsEnabled()
    }

    fun needsPermissionPrompt(ctx: Context) = Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED

    fun openNotificationSettings(activity: Activity) {
        activity.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName))
    }
}

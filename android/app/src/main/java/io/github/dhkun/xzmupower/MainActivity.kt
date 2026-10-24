package io.github.dhkun.xzmupower

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.core.widget.NestedScrollView
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.card.MaterialCardView
import com.google.android.material.color.MaterialColors
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.progressindicator.CircularProgressIndicator
import com.google.android.material.snackbar.Snackbar
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : AppCompatActivity() {

    private val exec = Executors.newSingleThreadExecutor()
    private lateinit var swipe: SwipeRefreshLayout
    private var querying = false
    private var errorText: String? = null

    private val notifyPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            // 拒绝过且系统不再弹框时, 直接去系统通知设置
            if (!granted && !shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
                openNotificationSettings()
            }
            render()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        AlertNotify.ensureChannels(this)
        if (!Prefs.configured(this)) {
            startActivity(Intent(this, SetupActivity::class.java))
            finish()
            return
        }
        setContentView(R.layout.activity_main)

        // 底部手势条留白, 内容可滚到其下方
        val scroll = findViewById<NestedScrollView>(R.id.scroll)
        val basePad = scroll.paddingBottom
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { v, insets ->
            v.updatePadding(bottom = basePad + insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom)
            insets
        }

        findViewById<MaterialToolbar>(R.id.toolbar).setOnMenuItemClickListener {
            if (it.itemId == R.id.action_refresh) {
                swipe.isRefreshing = true
                query()
            }
            true
        }
        swipe = findViewById(R.id.swipe)
        swipe.setColorSchemeColors(MaterialColors.getColor(swipe, androidx.appcompat.R.attr.colorPrimary))
        swipe.setOnRefreshListener { query() }

        findViewById<View>(R.id.rowNotify).setOnClickListener { toggleNotify() }
        findViewById<View>(R.id.rowThreshold).setOnClickListener { pickThreshold() }
        findViewById<View>(R.id.rowAuto).setOnClickListener {
            Snackbar.make(it, "由系统 WorkManager 调度, 省电模式下可能延后", Snackbar.LENGTH_SHORT).show()
        }
        findViewById<View>(R.id.rowRebind).setOnClickListener { openSetup() }
        findViewById<View>(R.id.bannerBtn).setOnClickListener { openSetup() }

        schedulePeriodic()
        if (Build.VERSION.SDK_INT >= 33 && !notificationsOn()) {
            notifyPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    override fun onResume() {
        super.onResume()
        if (!Prefs.configured(this)) return
        render()
        if (System.currentTimeMillis() - Prefs.lastCheck(this) > 60_000) {
            swipe.isRefreshing = true
            query()
        }
    }

    private fun openSetup() {
        // 不清空现有绑定: 新房间验证成功后才替换
        startActivity(Intent(this, SetupActivity::class.java).putExtra(SetupActivity.EXTRA_REBIND, true))
    }

    private fun query() {
        if (querying) return
        querying = true
        exec.execute {
            val r = PowerSync.sync(this)
            runOnUiThread {
                querying = false
                swipe.isRefreshing = false
                errorText = when {
                    r.sessionDead -> "登录已过期, 重新登录后即可恢复查询"
                    !r.ok -> "查询失败: ${r.message}"
                    else -> null
                }
                render()
            }
        }
    }

    private fun render() {
        val v = PowerStatus.load(this)
        findViewById<TextView>(R.id.roomText).text = v.room.ifBlank { "我的宿舍" }
        findViewById<TextView>(R.id.qtyText).text = PowerStatus.fmtQty(v.qty)
        findViewById<TextView>(R.id.percentText).text = "${v.percent}%"
        findViewById<TextView>(R.id.timeText).text =
            if (querying) "正在查询…" else PowerStatus.fmtTime(v.lastAt)
        findViewById<CircularProgressIndicator>(R.id.ring).setProgressCompat(v.percent, true)

        findViewById<View>(R.id.levelPill).visibility = if (v.qty >= 0) View.VISIBLE else View.INVISIBLE
        findViewById<TextView>(R.id.levelText).text = v.level.text
        findViewById<View>(R.id.levelDot).backgroundTintList = ColorStateList.valueOf(levelColor(v.level))

        findViewById<TextView>(R.id.daysText).text = if (v.daysLeft >= 0) v.daysLeft.toString() else "--"
        findViewById<TextView>(R.id.daysSub).text = if (v.daysLeft >= 0) "按近期用电估算" else "数据积累中"
        findViewById<TextView>(R.id.dailyText).text =
            if (v.dailyUse > 0) String.format(Locale.CHINA, "%.1f", v.dailyUse) else "--"
        findViewById<TextView>(R.id.dailySub).text = if (v.dailyUse > 0) "自上次充值以来" else "至少需要 6 小时数据"

        val banner = errorText ?: if (v.sessionDead) "登录已过期, 重新登录后即可恢复查询" else null
        findViewById<MaterialCardView>(R.id.banner).visibility = if (banner != null) View.VISIBLE else View.GONE
        findViewById<TextView>(R.id.bannerText).text = banner

        val on = notificationsOn()
        findViewById<MaterialSwitch>(R.id.notifySwitch).isChecked = on
        findViewById<TextView>(R.id.notifySub).text = if (on) "低于阈值时提醒充值" else "已关闭, 点按开启"
        findViewById<TextView>(R.id.thresholdSub).text = "剩余低于 ${PowerStatus.fmtQty(v.threshold)} 度时提醒"
    }

    private fun levelColor(level: PowerLevel): Int = when (level) {
        PowerLevel.OK -> ContextCompat.getColor(this, R.color.level_ok)
        PowerLevel.WARN -> ContextCompat.getColor(this, R.color.level_warn)
        PowerLevel.LOW -> MaterialColors.getColor(swipe, androidx.appcompat.R.attr.colorError)
        PowerLevel.UNKNOWN -> MaterialColors.getColor(swipe, com.google.android.material.R.attr.colorOutline)
    }

    private fun pickThreshold() {
        val values = arrayOf(5f, 10f, 15f, 20f, 30f, 50f, 80f, 100f)
        val current = values.indexOfFirst { it == Prefs.threshold(this) }
        MaterialAlertDialogBuilder(this)
            .setTitle("提醒阈值")
            .setSingleChoiceItems(values.map { "${PowerStatus.fmtQty(it)} 度" }.toTypedArray(), current) { d, i ->
                Prefs.setThreshold(this, values[i])
                AlertEval.reevaluateWithLast(this)
                render()
                d.dismiss()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun notificationsOn(): Boolean {
        val granted = Build.VERSION.SDK_INT < 33 ||
                ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        return granted && NotificationManagerCompat.from(this).areNotificationsEnabled()
    }

    /** 未授权先走系统授权框, 其余情况(含关闭)进系统通知设置 */
    private fun toggleNotify() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED) {
            notifyPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            openNotificationSettings()
        }
    }

    private fun openNotificationSettings() {
        startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
    }

    private fun schedulePeriodic() {
        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            QueryWorker.PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<QueryWorker>(QueryWorker.HOURS, TimeUnit.HOURS).build()
        )
    }
}

package io.github.dhkun.xzmupower

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.core.widget.NestedScrollView
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.snackbar.Snackbar

/** 设置页: Pixel 设置风格的分组列表 */
class SettingsActivity : AppCompatActivity() {

    private val notifyPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            // 拒绝过且系统不再弹框时, 直接去系统通知设置
            if (!granted && !shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
                Actions.openNotificationSettings(this)
            }
            render()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        val scroll = findViewById<NestedScrollView>(R.id.scroll)
        val basePad = scroll.paddingBottom
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { v, insets ->
            v.updatePadding(bottom = basePad + insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom)
            insets
        }
        findViewById<MaterialToolbar>(R.id.toolbar).setNavigationOnClickListener { finish() }

        findViewById<View>(R.id.rowNotify).setOnClickListener {
            if (Actions.needsPermissionPrompt(this)) {
                notifyPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                Actions.openNotificationSettings(this)
            }
        }
        findViewById<View>(R.id.rowThreshold).setOnClickListener { Actions.pickThreshold(this) { render() } }
        findViewById<View>(R.id.rowDynamic).apply {
            isEnabled = Build.VERSION.SDK_INT >= 31
            setOnClickListener {
                Prefs.setDynamicColor(this@SettingsActivity, !Prefs.dynamicColor(this@SettingsActivity))
                // 配色在页面创建时决定, 重建本页立即生效; 首页回来时自己重建
                recreate()
            }
        }
        findViewById<View>(R.id.rowWidget).setOnClickListener { Actions.pinWidget(this, it) }
        findViewById<View>(R.id.rowAuto).setOnClickListener {
            Snackbar.make(it, "由系统 WorkManager 调度, 省电模式下可能延后", Snackbar.LENGTH_SHORT).show()
        }
        findViewById<View>(R.id.rowRebind).setOnClickListener {
            startActivity(Intent(this, SetupActivity::class.java).putExtra(SetupActivity.EXTRA_REBIND, true))
        }
        findViewById<View>(R.id.rowAutoLogin).setOnClickListener {
            if (Credentials.has(this)) {
                com.google.android.material.dialog.MaterialAlertDialogBuilder(this)
                    .setTitle("关闭自动续期")
                    .setMessage("将删除本机保存的登录密码, 之后会话过期需手动重新登录。")
                    .setPositiveButton("关闭并删除") { _, _ ->
                        Credentials.clear(this)
                        render()
                    }
                    .setNegativeButton("取消", null)
                    .show()
            } else {
                com.google.android.material.snackbar.Snackbar.make(it,
                    "在重新绑定宿舍时勾选\"记住密码\"即可开启", com.google.android.material.snackbar.Snackbar.LENGTH_LONG).show()
            }
        }
        findViewById<TextView>(R.id.versionSub).text = BuildConfig.VERSION_NAME
        // 长按版本号看最近的同步记录, 用来分辨是没被系统调度还是恢复失败
        findViewById<View>(R.id.rowVersion).setOnLongClickListener {
            com.google.android.material.dialog.MaterialAlertDialogBuilder(this)
                .setTitle("最近同步记录")
                .setMessage(Prefs.runLog(this).asReversed().joinToString("\n").ifEmpty { "暂无记录" })
                .setPositiveButton("关闭", null)
                .show()
            true
        }
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        val on = Actions.notificationsOn(this)
        findViewById<MaterialSwitch>(R.id.notifySwitch).isChecked = on
        findViewById<TextView>(R.id.notifySub).text = if (on) "低于阈值时提醒充值" else "已关闭, 收不到低电量提醒"
        findViewById<TextView>(R.id.thresholdSub).text =
            "剩余低于 ${PowerStatus.fmtQty(Prefs.threshold(this))} 度时提醒"

        val dynamicOk = Build.VERSION.SDK_INT >= 31
        findViewById<MaterialSwitch>(R.id.dynamicSwitch).apply {
            isChecked = dynamicOk && Prefs.dynamicColor(this@SettingsActivity)
            isEnabled = dynamicOk
        }
        findViewById<TextView>(R.id.dynamicSub).text =
            if (dynamicOk) "使用壁纸生成的 Material You 配色" else "需要 Android 12 及以上"
        findViewById<TextView>(R.id.roomSub).text = Prefs.roomLabel(this).ifBlank { "未绑定" }

        val hasCreds = Credentials.has(this)
        findViewById<com.google.android.material.materialswitch.MaterialSwitch>(R.id.autoLoginSwitch).isChecked = hasCreds
        findViewById<TextView>(R.id.autoLoginSub).text =
            if (hasCreds) "会话过期时用本机密码自动登录" else "未开启, 过期需手动重新登录"
    }
}

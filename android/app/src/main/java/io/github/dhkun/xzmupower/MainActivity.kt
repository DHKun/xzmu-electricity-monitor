package io.github.dhkun.xzmupower

import android.Manifest
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Intent
import android.content.res.ColorStateList
import android.os.Build
import android.os.Bundle
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.graphics.ColorUtils
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
import com.google.android.material.progressindicator.LinearProgressIndicator
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** 首页: 仿 Pixel 天气, 只放数据; 设置项在 SettingsActivity */
class MainActivity : AppCompatActivity() {

    private val exec = Executors.newSingleThreadExecutor()
    private lateinit var swipe: SwipeRefreshLayout
    private var querying = false
    private var errorText: String? = null
    /** 本页创建时是否用了壁纸取色; 设置里切换后回到首页需要重建 */
    private var appliedDynamic = false
    private var shownQty = -1f
    private var autoReloginActive = false
    /** 承载隐藏的自动登录 WebView */
    private val content: ViewGroup by lazy { findViewById(android.R.id.content) }

    private val notifyPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        AlertNotify.ensureChannels(this)
        // 调试构建: adb shell am start -n <包名>/.MainActivity --ez xzmu.demo true 写入示例数据
        if (BuildConfig.DEBUG && intent.getBooleanExtra("xzmu.demo", false)) {
            Prefs.seedDemo(this)
        }
        if (BuildConfig.DEBUG && intent.getBooleanExtra("xzmu.democreds", false)) {
            Credentials.save(this, Credentials.TYPE_WX, "demo_user", "demo_pass", "", "")
        }
        if (!Prefs.configured(this)) {
            startActivity(Intent(this, SetupActivity::class.java))
            finish()
            return
        }
        appliedDynamic = Prefs.dynamicColor(this)
        setContentView(R.layout.activity_main)

        // 底部手势条留白, 内容可滚到其下方
        val scroll = findViewById<NestedScrollView>(R.id.scroll)
        val basePad = scroll.paddingBottom
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { v, insets ->
            v.updatePadding(bottom = basePad + insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom)
            insets
        }

        findViewById<MaterialToolbar>(R.id.toolbar).setOnMenuItemClickListener {
            when (it.itemId) {
                R.id.action_refresh -> {
                    swipe.isRefreshing = true
                    query()
                }
                R.id.action_settings -> startActivity(Intent(this, SettingsActivity::class.java))
            }
            true
        }
        swipe = findViewById(R.id.swipe)
        swipe.setColorSchemeColors(MaterialColors.getColor(swipe, androidx.appcompat.R.attr.colorPrimary))
        swipe.setOnRefreshListener { query() }

        setupTiles()
        findViewById<View>(R.id.bannerBtn).setOnClickListener {
            startActivity(Intent(this, SetupActivity::class.java).putExtra(SetupActivity.EXTRA_REBIND, true))
        }

        schedulePeriodic()
        if (Actions.needsPermissionPrompt(this)) {
            notifyPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    override fun onResume() {
        super.onResume()
        if (!Prefs.configured(this)) return
        if (Prefs.dynamicColor(this) != appliedDynamic) {
            recreate()
            return
        }
        render()
        if (Prefs.sessionDead(this) && Credentials.has(this)) {
            // 已知会话过期且存了凭据: 直接静默续期, 不必先失败一次
            autoRelogin()
        } else if (System.currentTimeMillis() - Prefs.lastCheck(this) > 60_000) {
            swipe.isRefreshing = true
            query()
        }
    }

    private fun tile(id: Int): View = findViewById(id)

    private fun setupTiles() {
        fun init(id: Int, icon: Int, title: String) {
            tile(id).findViewById<ImageView>(R.id.tileIcon).setImageResource(icon)
            tile(id).findViewById<TextView>(R.id.tileTitle).text = title
        }
        init(R.id.tileRemain, R.drawable.ic_battery, "余量")
        init(R.id.tileDaily, R.drawable.ic_bolt, "日均用电")
        init(R.id.tileRunOut, R.drawable.ic_event, "预计用完")
        init(R.id.tileThreshold, R.drawable.ic_notifications, "提醒阈值")
        tile(R.id.tileThreshold).setOnClickListener { Actions.pickThreshold(this) { render() } }

        // 中等宽度单列时 4 张小卡排成一行
        if (resources.getBoolean(R.bool.tiles_one_row)) {
            val row1 = findViewById<LinearLayout>(R.id.tileRow1)
            val row2 = findViewById<LinearLayout>(R.id.tileRow2)
            listOf(R.id.tileRunOut, R.id.tileThreshold).forEach { id ->
                val v = tile(id)
                (v.parent as ViewGroup).removeView(v)
                row1.addView(v)
            }
            row2.visibility = View.GONE
        }
    }

    private fun setTile(id: Int, value: String, unit: String, desc: String) {
        tile(id).findViewById<TextView>(R.id.tileValue).text = value
        tile(id).findViewById<TextView>(R.id.tileUnit).text = unit
        tile(id).findViewById<TextView>(R.id.tileDesc).text = desc
    }

    private fun query(allowRelogin: Boolean = true) {
        if (querying) return
        querying = true
        render()
        exec.execute {
            val r = PowerSync.sync(this)
            runOnUiThread {
                querying = false
                swipe.isRefreshing = false
                // 会话过期且存了凭据: 先静默续期再查一次, 用户无感
                if (r.sessionDead && allowRelogin && Credentials.has(this)) {
                    autoRelogin()
                    return@runOnUiThread
                }
                errorText = when {
                    r.sessionDead -> "登录已过期, 重新登录后即可恢复查询"
                    !r.ok -> "查询失败: ${r.message}"
                    else -> null
                }
                if (r.ok && Build.VERSION.SDK_INT >= 30) {
                    swipe.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                }
                render()
            }
        }
    }

    /** 用保存的凭据在隐藏 WebView 里自动登录, 成功后再查一次 */
    private fun autoRelogin() {
        if (autoReloginActive) return
        autoReloginActive = true
        errorText = null
        render()
        SilentLogin(this, content).start { ok ->
            autoReloginActive = false
            if (ok) {
                query(allowRelogin = false)
            } else {
                errorText = "自动登录失败, 请手动重新登录"
                render()
            }
        }
    }

    private fun render() {
        val v = PowerStatus.load(this)
        findViewById<TextView>(R.id.roomText).text = v.room.ifBlank { "我的宿舍" }
        renderHero(v)

        // 自动续期进行中不弹"登录已过期", 以免吓人; 用顶部"正在自动登录…"表示进度
        val banner = when {
            autoReloginActive -> null
            errorText != null -> errorText
            v.sessionDead -> "登录已过期, 重新登录后即可恢复查询"
            else -> null
        }
        findViewById<MaterialCardView>(R.id.banner).visibility = if (banner != null) View.VISIBLE else View.GONE
        findViewById<TextView>(R.id.bannerText).text = banner

        findViewById<TextView>(R.id.weekAvgText).text =
            if (v.dailyUse > 0) String.format(Locale.CHINA, "日均 %.1f 度", v.dailyUse) else "数据积累中"
        findViewById<WeekChartView>(R.id.weekChart).setDays(v.week, animate = true)

        setTile(R.id.tileRemain, "${v.percent}", "%", "以上次充值后为满格")
        tile(R.id.tileRemain).findViewById<LinearProgressIndicator>(R.id.tileBar).apply {
            visibility = View.VISIBLE
            setProgressCompat(v.percent, true)
        }
        setTile(R.id.tileDaily,
            if (v.dailyUse > 0) String.format(Locale.CHINA, "%.1f", v.dailyUse) else "--", "度",
            if (v.dailyUse > 0) "自上次充值以来" else "至少需要 6 小时数据")
        setTile(R.id.tileRunOut,
            if (v.daysLeft >= 0) PowerStatus.runOutDate(v.daysLeft) else "--", "",
            if (v.daysLeft >= 0) "约 ${v.daysLeft} 天后" else "按近期用电估算")
        setTile(R.id.tileThreshold, PowerStatus.fmtQty(v.threshold), "度", "低于时通知 · 点按修改")
    }

    /** 主卡底色随电量: 充足主色容器, 偏低第三色(暖色)容器, 不足错误色容器 */
    private fun renderHero(v: PowerView) {
        val (bgAttr, fgAttr) = when (v.level) {
            PowerLevel.OK -> com.google.android.material.R.attr.colorPrimaryContainer to
                    com.google.android.material.R.attr.colorOnPrimaryContainer
            PowerLevel.WARN -> com.google.android.material.R.attr.colorTertiaryContainer to
                    com.google.android.material.R.attr.colorOnTertiaryContainer
            PowerLevel.LOW -> com.google.android.material.R.attr.colorErrorContainer to
                    com.google.android.material.R.attr.colorOnErrorContainer
            PowerLevel.UNKNOWN -> com.google.android.material.R.attr.colorSecondaryContainer to
                    com.google.android.material.R.attr.colorOnSecondaryContainer
        }
        val card = findViewById<MaterialCardView>(R.id.heroCard)
        val fg = MaterialColors.getColor(card, fgAttr)
        val fgSoft = ColorUtils.setAlphaComponent(fg, 0xC0)
        card.setCardBackgroundColor(MaterialColors.getColor(card, bgAttr))

        val qtyText = findViewById<TextView>(R.id.qtyText)
        qtyText.setTextColor(fg)
        animateQty(qtyText, v.qty)
        findViewById<TextView>(R.id.unitText).setTextColor(fgSoft)
        findViewById<TextView>(R.id.timeText).apply {
            setTextColor(fgSoft)
            text = when {
                autoReloginActive -> "正在自动登录…"
                querying -> "正在查询…"
                else -> PowerStatus.fmtTime(v.lastAt)
            }
        }
        findViewById<TextView>(R.id.summaryText).apply {
            setTextColor(fg)
            text = when {
                v.qty < 0 -> "暂无数据, 下拉刷新"
                v.daysLeft >= 0 -> "约可用 ${v.daysLeft} 天 · 预计 ${PowerStatus.runOutDate(v.daysLeft)} 用完"
                else -> "继续使用几天后可估算可用天数"
            }
        }
        findViewById<View>(R.id.levelPill).visibility = if (v.qty >= 0) View.VISIBLE else View.INVISIBLE
        findViewById<TextView>(R.id.levelText).text = v.level.text
        findViewById<View>(R.id.levelDot).backgroundTintList = ColorStateList.valueOf(levelColor(v.level))
    }

    /** 读数变化时数字滚动过去 */
    private fun animateQty(view: TextView, target: Float) {
        if (target < 0 || shownQty < 0 || shownQty == target) {
            view.text = PowerStatus.fmtQty(target)
            shownQty = target
            return
        }
        val from = shownQty
        shownQty = target
        val decimals = target != target.toLong().toFloat()
        ValueAnimator.ofFloat(from, target).apply {
            duration = 700
            addUpdateListener {
                val x = it.animatedValue as Float
                view.text = if (decimals) String.format(Locale.CHINA, "%.1f", x) else x.toLong().toString()
            }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    view.text = PowerStatus.fmtQty(target)
                }
            })
        }.start()
    }

    private fun levelColor(level: PowerLevel): Int = when (level) {
        PowerLevel.OK -> ContextCompat.getColor(this, R.color.level_ok)
        PowerLevel.WARN -> ContextCompat.getColor(this, R.color.level_warn)
        PowerLevel.LOW -> MaterialColors.getColor(swipe, androidx.appcompat.R.attr.colorError)
        PowerLevel.UNKNOWN -> MaterialColors.getColor(swipe, com.google.android.material.R.attr.colorOutline)
    }

    private fun schedulePeriodic() {
        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            QueryWorker.PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<QueryWorker>(QueryWorker.HOURS, TimeUnit.HOURS).build()
        )
    }
}

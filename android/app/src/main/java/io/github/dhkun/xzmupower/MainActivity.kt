package io.github.dhkun.xzmupower

import android.os.Bundle
import android.view.View
import android.webkit.CookieManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : AppCompatActivity() {

    private val exec = Executors.newSingleThreadExecutor()
    private lateinit var balanceText: TextView
    private lateinit var roomText: TextView
    private lateinit var statusText: TextView
    private lateinit var thresholdEdit: EditText
    private lateinit var progressBar: ProgressBar

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AlertNotify.ensureChannels(this)
        if (!Prefs.configured(this)) {
            startActivity(android.content.Intent(this, SetupActivity::class.java))
            finish()
            return
        }
        setContentView(R.layout.activity_main)

        roomText = findViewById(R.id.roomText)
        balanceText = findViewById(R.id.balanceText)
        statusText = findViewById(R.id.statusText)
        thresholdEdit = findViewById(R.id.thresholdEdit)
        progressBar = findViewById(R.id.progressBar)

        roomText.text = Prefs.roomLabel(this).ifBlank { "已绑定房间" }
        thresholdEdit.setText(fmt(Prefs.threshold(this)))
        Prefs.lastQty(this).takeIf { it >= 0 }?.let {
            balanceText.text = fmt(it)
            statusText.text = "上次查询: " + fmtTime(Prefs.lastCheck(this))
        }

        thresholdEdit.setOnFocusChangeListener { _, hasFocus ->
            if (!hasFocus) saveThreshold()
        }
        findViewById<Button>(R.id.queryBtn).setOnClickListener { manualQuery() }
        findViewById<Button>(R.id.rebindBtn).setOnClickListener {
            Prefs.clearBinding(this)
            startActivity(android.content.Intent(this, SetupActivity::class.java))
            finish()
        }

        schedulePeriodic()
        requestNotificationPermission()
        manualQuery()
    }

    private fun saveThreshold() {
        thresholdEdit.text.toString().toFloatOrNull()?.let {
            if (it >= 0) {
                Prefs.setThreshold(this, it)
                Toast.makeText(this, "阈值已保存: ${fmt(it)}度", Toast.LENGTH_SHORT).show()
                AlertEval.reevaluateWithLast(this)
            }
        }
    }

    private fun manualQuery() {
        progressBar.visibility = View.VISIBLE
        statusText.text = "查询中…"
        exec.execute {
            val r = PowerApi.queryRoomState(this, Prefs.payProId(this), Prefs.roomVerify(this))
            runOnUiThread {
                progressBar.visibility = View.GONE
                when {
                    r.sessionDead -> {
                        statusText.text = "登录已过期, 请点击\"重新绑定\""
                        Toast.makeText(this, "登录已过期, 点击\"重新绑定\"重新登录", Toast.LENGTH_LONG).show()
                    }
                    r.ok && r.quantity != null -> {
                        Prefs.setLastCheck(this, System.currentTimeMillis())
                        Prefs.setCookieSnapshot(this, PowerApi.sessionCookie(this))
                        balanceText.text = fmt(r.quantity!!.toFloat())
                        statusText.text = "上次查询: " + fmtTime(System.currentTimeMillis())
                        AlertEval.evaluate(this, r.quantity!!, r.unit)
                    }
                    else -> statusText.text = "查询失败: ${r.message}"
                }
            }
        }
    }

    private fun schedulePeriodic() {
        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            QueryWorker.PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<QueryWorker>(QueryWorker.HOURS, TimeUnit.HOURS).build()
        )
    }

    private fun requestNotificationPermission() {
        if (android.os.Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    private fun fmt(v: Float) = if (v == v.toLong().toFloat()) v.toInt().toString() else v.toString()
    private fun fmtTime(t: Long) =
        java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.CHINA).format(java.util.Date(t))
}

package io.github.dhkun.xzmupower

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import android.view.animation.DecelerateInterpolator
import androidx.core.graphics.ColorUtils
import com.google.android.material.color.MaterialColors
import java.util.Locale
import kotlin.math.max

/** 近 7 天用电柱状图: 顶部数值, 圆头柱子, 底部星期; 过去几天用浅一档的主色, 今天实色, 无数据的天画浅色短柱 */
class WeekChartView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null,
) : View(context, attrs) {

    private var days: List<DayUse> = emptyList()
    private var grow = 1f
    private val dp = resources.displayMetrics.density
    private val sp = resources.displayMetrics.scaledDensity

    private val barPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val rect = RectF()

    private val colorToday = MaterialColors.getColor(this, androidx.appcompat.R.attr.colorPrimary)
    private val colorBar = ColorUtils.setAlphaComponent(colorToday, 0x80)
    private val colorEmpty = MaterialColors.getColor(this, com.google.android.material.R.attr.colorSurfaceVariant)
    private val colorText = MaterialColors.getColor(this, com.google.android.material.R.attr.colorOnSurfaceVariant)
    private val colorTextToday = MaterialColors.getColor(this, com.google.android.material.R.attr.colorOnSurface)

    fun setDays(list: List<DayUse>, animate: Boolean) {
        val changed = list != days
        days = list
        if (animate && changed) {
            ValueAnimator.ofFloat(0f, 1f).apply {
                duration = 600
                interpolator = DecelerateInterpolator()
                addUpdateListener { grow = it.animatedValue as Float; invalidate() }
            }.start()
        } else {
            invalidate()
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), (148 * dp).toInt())
    }

    override fun onDraw(canvas: Canvas) {
        if (days.isEmpty()) return
        val colW = width / days.size.toFloat()
        val valueY = 14 * sp
        val labelY = height - 2 * dp
        val barTop = valueY + 10 * dp
        val barBottom = labelY - 14 * sp - 8 * dp
        val barH = barBottom - barTop
        val barW = 10 * dp
        val maxUse = max(days.maxOf { it.used }, 0.1f)

        days.forEachIndexed { i, d ->
            val cx = colW * i + colW / 2
            val today = i == days.lastIndex
            textPaint.textSize = 12 * sp
            textPaint.color = colorText
            canvas.drawText(if (d.used >= 0) String.format(Locale.CHINA, "%.1f", d.used) else "—", cx, valueY, textPaint)

            val h = if (d.used > 0) max(barW, d.used / maxUse * barH * grow) else barW
            rect.set(cx - barW / 2, barBottom - h, cx + barW / 2, barBottom)
            barPaint.color = when {
                d.used < 0 -> colorEmpty
                today -> colorToday
                else -> colorBar
            }
            canvas.drawRoundRect(rect, barW / 2, barW / 2, barPaint)

            textPaint.textSize = 12 * sp
            textPaint.color = if (today) colorTextToday else colorText
            textPaint.isFakeBoldText = today
            canvas.drawText(d.label, cx, labelY, textPaint)
            textPaint.isFakeBoldText = false
        }
    }
}

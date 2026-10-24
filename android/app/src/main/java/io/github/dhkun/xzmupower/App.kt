package io.github.dhkun.xzmupower

import android.app.Application
import com.google.android.material.color.DynamicColors
import com.google.android.material.color.DynamicColorsOptions

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        // 默认固定色板; 用户在设置里打开"跟随壁纸取色"后, 之后创建的页面改用壁纸动态色(Android 12+)
        DynamicColors.applyToActivitiesIfAvailable(this, DynamicColorsOptions.Builder()
            .setPrecondition { activity, _ -> Prefs.dynamicColor(activity) }
            .build())
    }
}

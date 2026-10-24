# XZMU电费 · HarmonyOS 版 (API 26 / 鸿蒙7)

与安卓版功能一致：内嵌页登录绑定 → 查询剩余电量 → 低电量通知。

## 鸿蒙特性

- **互动服务卡片**：桌面 2×2 卡片直接显示剩余电量，卡片上的"刷新"按钮通过
  `FormLink(call)` 在后台拉起查询并刷新卡片，不用打开 App
- **WorkScheduler 后台轮询**：`WorkSchedulerExtensionAbility` 每 2 小时择机查询，
  结果同步通知 + 桌面卡片
- **深浅色跟随系统**：`resources/dark/` 全套色板
- 一多适配（phone/tablet）、沉浸式状态栏

## 构建

需要 DevEco Studio 或本仓库使用的 Command Line Tools（26.0.0+，SDK API 26）：

```bash
export DEVECO_SDK_HOME=<工具链目录>/sdk
export PATH=<工具链目录>/bin:<工具链目录>/tool/node/bin:$PATH
cd harmonyos
ohpm install
hvigorw assembleHap --mode module -p product=default
# 产物: entry/build/default/outputs/default/entry-default-unsigned.hap
```

## 安装（需要签名）

HAP 必须签名后才能安装到真机/模拟器：

1. 在 [AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)
   创建应用并生成调试证书(.p12 + .cer + .p7b)
2. 在 `build-profile.json5` 的 `signingConfigs` 里配置签名材料
3. 重新执行 `hvigorw assembleHap` 得到已签名 HAP
4. 安装: `hdc install entry-default-signed.hap`

DevEco Studio 用户也可以直接 File → Project Structure → Signing Configs 勾选
"Automatically generate signature"（需华为开发者账号登录）。

# XZMU电费 · HarmonyOS 版 (API 26 / 鸿蒙7)

与安卓版功能一致：内嵌页登录绑定 → 查询剩余电量 → 低电量通知。

## 鸿蒙特性

- **iOS 风格界面**：分组列表、彩色圆角图标、深蓝渐变主卡 + 琥珀色圆环；
  `Navigation` Free 模式大标题随滚动收起，绑定页为 `NavDestination` 子页面
- **电量统计**：圆环以上次充值后的最高读数为满格；根据历史读数估算日均用电和
  预计可用天数；数字变化有翻牌动效
- **互动服务卡片**：2×2（读数 + 进度条）和 2×4（圆环），卡片上的刷新按钮通过
  `FormLink(message)` 在卡片进程直接查询，不用打开 App；App 内可一键拉起"添加卡片"面板
- **WorkScheduler 后台轮询**：约每 2 小时由系统择机查询，结果同步到通知和所有桌面卡片
- 下拉刷新、系统 Symbol 图标、低电量通知（未授权时跳转系统通知设置）、深浅色跟随系统

> 卡片和后台任务运行在独立进程，拿不到 WebView 会话，用的是绑定或上次成功查询时保存的
> Cookie 快照。服务端会话过期后，卡片会显示"登录已过期"，打开 App 重新绑定即可恢复。

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

## 安装（侧载）

Releases 里提供的是**未签名 HAP**（`XZMUPower-v1.0.0-harmonyos-unsigned.hap`）。
鸿蒙安装 HAP 必须有签名，请自行侧载，常用方式：

1. DevEco Studio 打开本工程 → File → Project Structure → Signing Configs →
   勾选 Automatically generate signature（登录自己的华为账号，免费）→
   重新 `hvigorw assembleHap` 得到已签名 HAP → `hdc install`
2. 或用社区侧载/自签名工具对未签名 HAP 重签后安装

不提供、也不背书任何签名材料。

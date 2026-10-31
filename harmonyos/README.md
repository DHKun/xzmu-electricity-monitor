# 民大电费 · HarmonyOS 版 (API 26 / 鸿蒙7)

与安卓版功能一致：内嵌页登录绑定 → 查询剩余电量 → 低电量通知。

## 鸿蒙特性

- **「天气」风格首页**：整屏天空渐变随电量变化（充足蓝天 / 偏低黄昏 / 不足暮红，深色模式为夜空），
  大号细体读数，毛玻璃卡片展示近 7 天用电柱状图、余量、日均用电、预计用完日期、提醒阈值
- **「设置」风格设置页**：系统色 token、分组圆角列表、彩色圆形图标、原生 `Toggle`
- **一多适配**：`GridRow` 断点布局，平板横屏左右两栏，竖屏/手机单列；设置页居中限宽；
  跟随系统旋转（`auto_rotation_restricted`）
- **互动服务卡片**：2×2（读数 + 进度条）和 2×4（圆环），背景与首页同一套天空渐变；
  卡片上的刷新按钮通过 `FormLink(message)` 在卡片进程直接查询，不用打开 App
- **WorkScheduler 后台轮询**：约每 2 小时由系统择机查询，结果同步到通知和所有桌面卡片
- 下拉刷新、系统 Symbol 图标、数字翻牌动效、低电量通知（未授权时跳转系统通知设置）

调试构建可以用示例数据直接查看已绑定界面（发布构建不生效）：

```bash
hdc shell aa start -a EntryAbility -b io.github.dhkun.xzmupower --pb xzmu.demo true
```

> 卡片和后台任务运行在独立进程，拿不到 WebView。后台任务发现会话过期时用本机保存的密码自行恢复，
> 不用打开 App；卡片进程寿命太短，只查询不恢复。确实需要人工处理时显示"需要重新登录"，打开 App 登录即可。
> 设置页点按版本号可看最近的同步记录。

## 构建

需要 DevEco Studio 或本仓库使用的 Command Line Tools（26.0.0+，SDK API 26）：

```bash
export DEVECO_SDK_HOME=<工具链目录>/sdk
export PATH=<工具链目录>/bin:<工具链目录>/tool/node/bin:$PATH
cd harmonyos
ohpm install
hvigorw assembleHap --mode module -p product=default -p buildMode=release
# 产物: entry/build/default/outputs/default/entry-default-unsigned.hap
```

同步逻辑层不依赖系统能力，可离线测试（在仓库根目录运行）：

```bash
node --experimental-transform-types --no-warnings harmonyos/logic-test/logic.test.mjs
```

## 安装（侧载）

Releases 里提供的是**未签名 HAP**（`MinDaPower-v<版本>-harmonyos-unsigned.hap`）。
鸿蒙安装 HAP 必须有签名，请自行侧载，常用方式：

1. DevEco Studio 打开本工程 → File → Project Structure → Signing Configs →
   勾选 Automatically generate signature（登录自己的华为账号，免费）→
   重新 `hvigorw assembleHap` 得到已签名 HAP → `hdc install`
2. 或用社区侧载/自签名工具对未签名 HAP 重签后安装

不提供、也不背书任何签名材料。

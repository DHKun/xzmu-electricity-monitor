import { common } from '@kit.AbilityKit';
import { uiObserver } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { Prefs } from '../service/Prefs';
import { PowerSync } from '../service/PowerSync';
import { Outcome, Stage, SyncReport, Trigger } from '../service/SyncEngine';
import { WebSession } from './WebSession';
import { DayUse, PowerLevel, PowerStatus, PowerView } from '../service/PowerStatus';
import { DATA_VERSION, pickThreshold, requestNotify } from './Actions';
import { setStatusBarLight } from './SystemBar';
import { Credentials, CredData } from '../service/Credentials';
import { SilentWeb } from './SilentWeb';
import { SetupPage } from './Setup';
import { SettingsPage } from './Settings';

/** 首页: 仿「天气」, 整屏天空渐变随电量变化, 下方毛玻璃卡片; 平板横屏左右两栏 */
@Entry
@Component
struct Index {
  private pathStack: NavPathStack = new NavPathStack();
  @StorageProp(DATA_VERSION) @Watch('onDataChanged') dataVersion: number = 0;
  @State view: PowerView = new PowerView();
  @State refreshing: boolean = false;
  @State querying: boolean = false;
  @State statusText: string = '';
  @State bp: string = 'sm';
  @State recovering: boolean = false;
  @State reloginActive: boolean = false;
  private reloginCreds: CredData = new CredData();
  private webFallbackTried: boolean = false;
  private notifyOn: boolean = true;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    Prefs.init(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.reload();
    // 子页面显示时状态栏用深色字, 全部退回首页后恢复白字
    this.getUIContext().getUIObserver().on('navDestinationUpdate', (info: uiObserver.NavDestinationInfo) => {
      if (info.state === uiObserver.NavDestinationState.ON_SHOWN) {
        setStatusBarLight(this.getUIContext(), false);
      } else if (info.state === uiObserver.NavDestinationState.ON_HIDDEN && this.pathStack.size() === 0) {
        setStatusBarLight(this.getUIContext(), true);
      }
    });
  }

  onPageShow(): void {
    this.reload();
    setStatusBarLight(this.getUIContext(), true);
    notificationManager.isNotificationEnabled().then((on: boolean) => {
      this.notifyOn = on;
    }).catch(() => {});
    if (this.view.configured && Date.now() - this.view.lastAt > 60 * 1000) {
      this.query();
    }
  }

  reload(): void {
    Prefs.reload();
    this.view = PowerStatus.load();
  }

  /** 设置页或绑定页改了数据; 首次绑定成功后顺带申请通知权限 */
  onDataChanged(): void {
    const wasConfigured: boolean = this.view.configured;
    this.reload();
    if (!wasConfigured && this.view.configured && !this.notifyOn) {
      requestNotify(this.getUIContext(), false, () => {});
    }
  }

  query(): void {
    if (this.querying || !this.view.configured) {
      this.refreshing = false;
      return;
    }
    this.querying = true;
    this.statusText = '';
    WebSession.migrateIfNeeded()
      .then(() => PowerSync.sync(Trigger.USER, () => false, () => {
        this.recovering = true;
      }))
      .then((r: SyncReport) => {
        this.onSynced(r);
      })
      .catch(() => {
        this.statusText = '查询失败, 请检查网络';
        this.finishQuery();
      });
  }

  onSynced(r: SyncReport): void {
    this.finishQuery();
    // 登录协议对不上时才退回页面方式, 每次打开页面最多一次
    if (r.outcome === Outcome.UNKNOWN && r.stage === Stage.AUTH && !this.webFallbackTried && Credentials.has()) {
      this.webFallbackTried = true;
      this.autoRelogin();
      return;
    }
    if (r.outcome === Outcome.TRANSIENT || r.outcome === Outcome.UNKNOWN) {
      this.statusText = `查询失败: ${r.message}`;
    } else if (r.outcome === Outcome.SKIPPED) {
      this.statusText = r.message;
    }
  }

  finishQuery(): void {
    this.querying = false;
    this.recovering = false;
    this.refreshing = false;
    this.reload();
  }

  /** 隐藏 Web 登录, 成功后换入新会话再查一次 */
  autoRelogin(): void {
    if (this.reloginActive) {
      return;
    }
    const c: CredData | null = Credentials.load();
    if (c === null) {
      this.statusText = '自动登录失败, 请手动重新登录';
      return;
    }
    this.reloginCreds = c;
    this.statusText = '';
    this.reloginActive = true;
  }

  onReloginResult(ok: boolean): void {
    this.reloginActive = false;
    if (ok) {
      WebSession.adopt().then(() => {
        this.query();
      }).catch(() => {
        this.statusText = '自动登录失败, 请手动重新登录';
      });
    } else {
      this.statusText = '自动登录失败, 请手动重新登录';
      this.reload();
    }
  }

  push(name: string): void {
    this.pathStack.pushPath(new NavPathInfo(name, ''));
  }

  skyTop(): ResourceColor {
    switch (this.view.level) {
      case PowerLevel.OK:
        return $r('app.color.sky_ok_top');
      case PowerLevel.WARN:
        return $r('app.color.sky_warn_top');
      case PowerLevel.LOW:
        return $r('app.color.sky_low_top');
      default:
        return $r('app.color.sky_none_top');
    }
  }

  skyBottom(): ResourceColor {
    switch (this.view.level) {
      case PowerLevel.OK:
        return $r('app.color.sky_ok_bottom');
      case PowerLevel.WARN:
        return $r('app.color.sky_warn_bottom');
      case PowerLevel.LOW:
        return $r('app.color.sky_low_bottom');
      default:
        return $r('app.color.sky_none_bottom');
    }
  }

  /** "电量充足 · 约可用 40 天" */
  headline(): string {
    if (this.view.qty < 0) {
      return '暂无数据, 下拉刷新';
    }
    const days: string = this.view.daysLeft >= 0 ? ` · 约可用 ${this.view.daysLeft} 天` : '';
    return `${PowerStatus.levelText(this.view.level)}${days}`;
  }

  wide(): boolean {
    return this.bp === 'lg';
  }

  @Styles
  glass() {
    .backgroundColor($r('app.color.glass'))
    .borderRadius(24)
  }

  @Builder
  routes(name: string, param: Object) {
    if (name === 'setup') {
      SetupPage()
    } else if (name === 'settings') {
      SettingsPage()
    }
  }

  @Builder
  roundButton(symbol: Resource, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(symbol)
        .fontSize(20)
        .fontColor([$r('app.color.on_sky')])
    }
    .width(40)
    .height(40)
    .backgroundColor($r('app.color.glass'))
    .onClick(action)
  }

  @Builder
  topBar() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.house_fill'))
        .fontSize(18)
        .fontColor([$r('app.color.on_sky')])
      Text(this.view.configured ? (this.view.room.length > 0 ? this.view.room : '我的宿舍') : '民大电费')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_sky'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.view.configured) {
        if (this.querying) {
          Row() {
            LoadingProgress().width(22).height(22).color($r('app.color.on_sky'))
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.glass'))
        } else {
          this.roundButton($r('sys.symbol.arrow_clockwise'), () => this.query())
        }
      }
      this.roundButton($r('sys.symbol.gearshape'), () => this.push('settings'))
    }
    .width('100%')
    .height(56)
    .padding({ left: 20, right: 16 })
  }

  /** 大号读数, 平板横屏左对齐, 其余居中 */
  @Builder
  hero() {
    Column() {
      Row() {
        Text(PowerStatus.fmtQty(this.view.qty))
          .fontSize(this.wide() ? 128 : 104)
          .fontWeight(FontWeight.Lighter)
          .fontColor($r('app.color.on_sky'))
          .maxLines(1)
          .contentTransition(new NumericTextTransition({ flipDirection: FlipDirection.DOWN, enableBlur: false }))
        Text('度')
          .fontSize(28)
          .fontWeight(FontWeight.Lighter)
          .fontColor($r('app.color.on_sky'))
          .margin({ top: this.wide() ? 30 : 24, left: 4 })
      }
      .alignItems(VerticalAlign.Top)

      Text(this.headline())
        .fontSize(20)
        .fontColor($r('app.color.on_sky'))
      Text(this.reloginActive || this.recovering ? '正在自动登录…' : (this.querying ? '正在查询…' : PowerStatus.fmtTime(this.view.lastAt)))
        .fontSize(14)
        .fontColor($r('app.color.on_sky_secondary'))
        .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(this.wide() ? HorizontalAlign.Start : HorizontalAlign.Center)
    .padding({ left: this.wide() ? 12 : 0, top: this.wide() ? 48 : 24, bottom: 28 })
  }

  @Builder
  banner() {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
        .fontSize(18)
        .fontColor([$r('app.color.on_sky')])
      Text(this.statusText.length > 0 ? this.statusText : '需要重新登录, 登录后即可恢复监控')
        .fontSize(14)
        .fontColor($r('app.color.on_sky'))
        .layoutWeight(1)
      if (this.view.needsLogin) {
        Text('重新登录')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_sky'))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor($r('app.color.glass'))
          .onClick(() => this.push('setup'))
      }
    }
    .width('100%')
    .padding(16)
    .glass()
  }

  /** 近 7 天柱状图, 类似「天气」的逐小时预报条 */
  @Builder
  weekCard() {
    Column() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.calendar'))
          .fontSize(14)
          .fontColor([$r('app.color.on_sky_secondary')])
        Text('近 7 天用电')
          .fontSize(14)
          .fontColor($r('app.color.on_sky_secondary'))
          .layoutWeight(1)
        Text(this.view.dailyUse > 0 ? `日均 ${this.view.dailyUse.toFixed(1)} 度` : '数据积累中')
          .fontSize(13)
          .fontColor($r('app.color.on_sky_secondary'))
      }
      .width('100%')

      Divider()
        .color($r('app.color.glass_track'))
        .strokeWidth(0.5)
        .margin({ top: 12, bottom: 12 })

      Row() {
        ForEach(this.view.week, (d: DayUse, i: number) => {
          Column({ space: 6 }) {
            Text(d.used >= 0 ? d.used.toFixed(1) : '—')
              .fontSize(12)
              .fontColor($r('app.color.on_sky_secondary'))
            Stack({ alignContent: Alignment.Bottom }) {
              Column()
                .width(10)
                .height(this.barHeight(d))
                .borderRadius(5)
                .backgroundColor(d.used < 0 ? $r('app.color.glass_track')
                  : (i === this.view.week.length - 1 ? $r('app.color.power_amber') : $r('app.color.on_sky')))
            }
            .height(84)
            Text(d.label)
              .fontSize(12)
              .fontColor(i === this.view.week.length - 1 ? $r('app.color.on_sky') : $r('app.color.on_sky_secondary'))
          }
          .layoutWeight(1)
        }, (d: DayUse, i: number) => `${i}-${d.label}-${d.used}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .glass()
  }

  barHeight(d: DayUse): number {
    let max: number = 0;
    this.view.week.forEach((x: DayUse) => {
      max = Math.max(max, x.used);
    });
    if (d.used <= 0 || max <= 0) {
      return 6;
    }
    return Math.max(6, d.used / max * 84);
  }

  /** 信息小卡, 类似「天气」的湿度/风速卡 */
  @Builder
  tile(symbol: Resource, title: string, value: string, unit: string, desc: string, percent: number,
       action: () => void) {
    Column() {
      Row({ space: 6 }) {
        SymbolGlyph(symbol)
          .fontSize(14)
          .fontColor([$r('app.color.on_sky_secondary')])
        Text(title)
          .fontSize(14)
          .fontColor($r('app.color.on_sky_secondary'))
      }

      Blank()

      Row({ space: 3 }) {
        Text(value)
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_sky'))
          .maxLines(1)
        Text(unit)
          .fontSize(14)
          .fontColor($r('app.color.on_sky_secondary'))
          .margin({ bottom: 5 })
      }
      .alignItems(VerticalAlign.Bottom)

      if (percent >= 0) {
        Progress({ value: percent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(6)
          .color($r('app.color.on_sky'))
          .backgroundColor($r('app.color.glass_track'))
          .style({ strokeWidth: 6, strokeRadius: 3 })
          .margin({ top: 8 })
      }
      Text(desc)
        .fontSize(12)
        .fontColor($r('app.color.on_sky_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 6 })
    }
    .width('100%')
    .height(150)
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .glass()
    .onClick(action)
  }

  @Builder
  tiles() {
    GridRow({ columns: { xs: 2, sm: 2, md: 4, lg: 2 }, gutter: { x: 12, y: 12 } }) {
      GridCol({ span: 1 }) {
        this.tile($r('sys.symbol.battery_50percent'), '余量', `${this.view.percent}`, '%', '以上次充值后为满格',
          this.view.percent, () => {})
      }
      GridCol({ span: 1 }) {
        this.tile($r('sys.symbol.bolt_fill'), '日均用电',
          this.view.dailyUse > 0 ? this.view.dailyUse.toFixed(1) : '--', '度',
          this.view.dailyUse > 0 ? '自上次充值以来' : '至少需要 6 小时数据', -1, () => {})
      }
      GridCol({ span: 1 }) {
        this.tile($r('sys.symbol.clock'), '预计用完',
          this.view.daysLeft >= 0 ? PowerStatus.runOutDate(this.view.daysLeft) : '--', '',
          this.view.daysLeft >= 0 ? `约 ${this.view.daysLeft} 天后` : '按近期用电估算', -1, () => {})
      }
      GridCol({ span: 1 }) {
        this.tile($r('sys.symbol.bell_fill'), '提醒阈值', PowerStatus.fmtQty(this.view.threshold), '度',
          '低于时通知 · 点按修改', -1,
          () => pickThreshold(this.getUIContext(), this.view.threshold, () => this.reload()))
      }
    }
  }

  @Builder
  cards() {
    Column({ space: 12 }) {
      if (!this.reloginActive && (this.statusText.length > 0 || this.view.needsLogin)) {
        this.banner()
      }
      this.weekCard()
      this.tiles()
      Text('数据来自完美校园云缴费 · 下拉刷新')
        .fontSize(12)
        .fontColor($r('app.color.on_sky_tertiary'))
        .margin({ top: 8 })
    }
    .width('100%')
  }

  @Builder
  emptyState() {
    Column({ space: 12 }) {
      Image($r('app.media.startIcon'))
        .width(96)
        .height(96)
        .margin({ bottom: 8 })
      Text('绑定你的宿舍')
        .fontSize(28)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_sky'))
      Text('用完美校园帐号登录, 在缴费页选中房间, 看到剩余电量后自动完成绑定')
        .fontSize(15)
        .fontColor($r('app.color.on_sky_secondary'))
        .textAlign(TextAlign.Center)
        .constraintSize({ maxWidth: 360 })
      Button('开始绑定', { type: ButtonType.Capsule })
        .width(240)
        .height(48)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.sky_none_top'))
        .backgroundColor(Color.White)
        .margin({ top: 16 })
        .onClick(() => this.push('setup'))
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 96, bottom: 48 })
  }

  build() {
    Navigation(this.pathStack) {
      Stack({ alignContent: Alignment.Top }) {
        // 续期时才构建的隐藏登录 Web(1×1 透明)
        if (this.reloginActive) {
          SilentWeb({ creds: this.reloginCreds, onResult: (ok: boolean) => this.onReloginResult(ok) })
        }

        // 天空渐变铺满整屏, 包括状态栏和导航条区域
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({ angle: 180, colors: [[this.skyTop(), 0], [this.skyBottom(), 1]] })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          .animation({ duration: 400 })

        Column() {
          this.topBar()
          Refresh({ refreshing: $$this.refreshing }) {
            Scroll(this.scroller) {
              Column() {
                if (this.view.configured) {
                  GridRow({
                    columns: { xs: 4, sm: 4, md: 8, lg: 12 },
                    gutter: { x: 24 },
                    breakpoints: { value: ['320vp', '600vp', '840vp'], reference: BreakpointsReference.WindowSize }
                  }) {
                    GridCol({ span: { xs: 4, sm: 4, md: 8, lg: 5 } }) {
                      this.hero()
                    }
                    GridCol({ span: { xs: 4, sm: 4, md: 8, lg: 7 } }) {
                      this.cards()
                    }
                  }
                  .onBreakpointChange((bp: string) => {
                    this.bp = bp;
                  })
                } else {
                  this.emptyState()
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 32 })
            }
            .width('100%')
            .height('100%')
            .align(Alignment.Top)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          }
          .onRefreshing(() => this.query())
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .hideToolBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.routes)
  }
}

import { common, Want } from '@kit.AbilityKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { formProvider } from '@kit.FormKit';
import { notificationManager } from '@kit.NotificationKit';
import { Prefs } from '../service/Prefs';
import { PowerApi, RoomState } from '../service/PowerApi';
import { AlertEval } from '../service/AlertEval';
import { PowerSync } from '../service/PowerSync';
import { PowerLevel, PowerStatus, PowerView } from '../service/PowerStatus';
import { SetupPage } from './Setup';

const THRESHOLDS: string[] = ['5', '10', '15', '20', '30', '50', '80', '100'];

/** 圆环: 琥珀色渐变, 与图标闪电同色 */
const RING_GRADIENT: LinearGradient = new LinearGradient([
  { color: $r('app.color.power_amber'), offset: 0 },
  { color: $r('app.color.power_amber_deep'), offset: 1 }
]);

@Entry
@Component
struct Index {
  private pathStack: NavPathStack = new NavPathStack();
  @State view: PowerView = new PowerView();
  @State refreshing: boolean = false;
  @State querying: boolean = false;
  @State statusText: string = '';
  @State notifyOn: boolean = true;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    Prefs.init(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.reload();
  }

  onPageShow(): void {
    this.reload();
    this.checkNotify();
    if (this.view.configured && Date.now() - this.view.lastAt > 60 * 1000) {
      this.query();
    }
  }

  reload(): void {
    Prefs.reload();
    this.view = PowerStatus.load();
  }

  checkNotify(): void {
    notificationManager.isNotificationEnabled().then((on: boolean) => {
      this.notifyOn = on;
    }).catch(() => {});
  }

  query(): void {
    if (this.querying || !this.view.configured) {
      this.refreshing = false;
      return;
    }
    this.querying = true;
    this.statusText = '';
    let live: string = '';
    try {
      live = PowerApi.sessionCookie();
    } catch (e) {
      // WebView 内核未就绪时拿不到实时会话, 用快照
    }
    PowerSync.syncNow(live).then((r: RoomState) => {
      if (r.sessionDead) {
        this.statusText = '登录已过期, 请重新绑定以恢复查询';
      } else if (!r.ok) {
        this.statusText = `查询失败: ${r.message}`;
      }
      this.finishQuery();
    }).catch(() => {
      this.statusText = '查询失败, 请检查网络';
      this.finishQuery();
    });
  }

  finishQuery(): void {
    this.querying = false;
    this.refreshing = false;
    this.reload();
  }

  openSetup(): void {
    // Setup 绑定成功后 pop('bound') 才会回调; 首次绑定顺带申请通知权限
    this.pathStack.pushPath(new NavPathInfo('setup', '', (info: PopInfo) => {
      this.reload();
      if (!this.notifyOn) {
        this.requestNotify();
      }
    }));
  }

  pickThreshold(): void {
    const current: string = String(this.view.threshold);
    const idx: number = THRESHOLDS.indexOf(current);
    this.getUIContext().showTextPickerDialog({
      range: THRESHOLDS.map((t: string) => `${t} 度`),
      selected: idx >= 0 ? idx : 3,
      onAccept: (v: TextPickerResult) => {
        const i: number = typeof v.index === 'number' ? v.index : 3;
        const val: number = Number(THRESHOLDS[i]);
        Prefs.setThreshold(val).then(() => {
          AlertEval.reevaluateWithLast();
          this.reload();
        });
      }
    });
  }

  /**
   * 未授权时先弹系统授权框; 被拒绝过或系统不再弹框时 requestEnableNotification 会直接失败,
   * 这时跳到本应用的通知设置页. 已开启时点按也进设置页, 方便关闭.
   */
  requestNotify(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (this.notifyOn) {
      this.openNotifySettings(ctx);
      return;
    }
    notificationManager.requestEnableNotification(ctx).then(() => {
      this.checkNotify();
    }).catch(() => {
      this.openNotifySettings(ctx);
    });
  }

  openNotifySettings(ctx: common.UIAbilityContext): void {
    notificationManager.openNotificationSettings(ctx).then(() => {
      this.checkNotify();
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '请在 设置 → 通知和状态栏 中允许 XZMU电费 通知' });
    });
  }

  /** 拉起系统"添加卡片"面板 */
  addCard(): void {
    const want: Want = {
      bundleName: 'io.github.dhkun.xzmupower',
      abilityName: 'EntryFormAbility',
      parameters: {
        'ohos.extra.param.key.form_dimension': 2,
        'ohos.extra.param.key.form_name': 'PowerCard',
        'ohos.extra.param.key.module_name': 'entry'
      }
    };
    try {
      formProvider.openFormManager(want);
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '请在桌面双指捏合 → 服务卡片中添加' });
    }
  }

  levelColor(level: PowerLevel): ResourceColor {
    switch (level) {
      case PowerLevel.LOW:
        return $r('app.color.power_red');
      case PowerLevel.WARN:
        return $r('app.color.power_orange');
      case PowerLevel.OK:
        return $r('app.color.power_green');
      default:
        return $r('app.color.power_gray');
    }
  }

  titleInfo(): NavigationCommonTitle {
    const t: NavigationCommonTitle = {
      main: '宿舍电费',
      sub: this.view.configured ? (this.view.room.length > 0 ? this.view.room : '已绑定') : '尚未绑定'
    };
    return t;
  }

  @Builder
  routes(name: string, param: Object) {
    if (name === 'setup') {
      SetupPage()
    }
  }

  /** 顶部主卡: 深蓝渐变, 与图标同色系 */
  @Builder
  hero() {
    Column() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.bolt_fill'))
          .fontSize(15)
          .fontColor([$r('app.color.power_amber')])
        Text(this.view.room.length > 0 ? this.view.room : '我的宿舍')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hero_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Row({ space: 5 }) {
          Circle()
            .width(7)
            .height(7)
            .fill(this.levelColor(this.view.level))
          Text(PowerStatus.levelText(this.view.level))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.hero_label'))
        }
        .padding({ left: 9, right: 10, top: 4, bottom: 4 })
        .borderRadius(11)
        .backgroundColor($r('app.color.hero_fill'))
        .visibility(this.view.qty >= 0 ? Visibility.Visible : Visibility.Hidden)
      }
      .width('100%')

      Row({ space: 20 }) {
        Stack() {
          Progress({ value: this.view.percent, total: 100, type: ProgressType.Ring })
            .width(124)
            .height(124)
            .color(RING_GRADIENT)
            .backgroundColor($r('app.color.hero_fill'))
            .style({ strokeWidth: 13 })
          Column() {
            Text(`${this.view.percent}%`)
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.hero_label'))
            Text('余量')
              .fontSize(11)
              .fontColor($r('app.color.hero_tertiary'))
          }
        }

        Column() {
          Row({ space: 4 }) {
            Text(PowerStatus.fmtQty(this.view.qty))
              .fontSize(54)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.hero_label'))
              .maxLines(1)
              .contentTransition(new NumericTextTransition({ flipDirection: FlipDirection.DOWN, enableBlur: false }))
            Text('度')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.hero_secondary'))
              .margin({ bottom: 10 })
          }
          .alignItems(VerticalAlign.Bottom)

          Text('剩余电量')
            .fontSize(14)
            .fontColor($r('app.color.hero_secondary'))

          Row({ space: 6 }) {
            if (this.querying) {
              LoadingProgress().width(14).height(14).color($r('app.color.hero_tertiary'))
            }
            Text(this.querying ? '正在查询…' : PowerStatus.fmtTime(this.view.lastAt))
              .fontSize(12)
              .fontColor($r('app.color.hero_tertiary'))
          }
          .margin({ top: 14 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 20 })
    }
    .width('100%')
    .padding(20)
    .borderRadius(26)
    .linearGradient({
      angle: 135,
      colors: [[$r('app.color.hero_start'), 0], [$r('app.color.hero_end'), 1]]
    })
    .shadow({ radius: 24, color: '#33141F4A', offsetY: 8 })
  }

  @Builder
  alertBanner() {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
        .fontSize(16)
        .fontColor([$r('app.color.power_red')])
      Text(this.statusText.length > 0 ? this.statusText : '登录已过期, 请重新绑定以恢复查询')
        .fontSize(14)
        .fontColor($r('app.color.power_label'))
        .layoutWeight(1)
      Text('重新登录')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.power_accent'))
        .onClick(() => this.openSetup())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(14)
    .backgroundColor($r('app.color.power_card'))
  }

  /** iOS 设置风格的彩色圆角图标 */
  @Builder
  iconTile(icon: Resource, tint: ResourceColor, size: number) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(size * 0.55)
        .fontColor([Color.White])
    }
    .width(size)
    .height(size)
    .borderRadius(size * 0.24)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(tint)
  }

  @Builder
  tile(icon: Resource, tint: ResourceColor, value: string, unit: string, title: string, note: string,
       action: () => void) {
    Column() {
      this.iconTile(icon, tint, 30)
      Row({ space: 3 }) {
        Text(value)
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.power_label'))
        Text(unit)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.power_secondary'))
          .margin({ bottom: 5 })
      }
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 14 })
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.power_label'))
        .margin({ top: 2 })
      Text(note)
        .fontSize(12)
        .fontColor($r('app.color.power_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
    }
    .width('100%')
    .padding(16)
    .borderRadius(20)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.power_card'))
    .onClick(action)
  }

  @Builder
  stats() {
    Row({ space: 12 }) {
      Column() {
        this.tile($r('sys.symbol.timer'), $r('app.color.power_indigo'),
          this.view.daysLeft >= 0 ? String(this.view.daysLeft) : '--', '天', '预计可用',
          this.view.dailyUse > 0 ? `日均 ${this.view.dailyUse.toFixed(1)} 度` : '数据积累中', () => {})
      }
      .layoutWeight(1)

      Column() {
        this.tile($r('sys.symbol.bell_fill'), $r('app.color.power_orange'),
          PowerStatus.fmtQty(this.view.threshold), '度', '提醒阈值', '点按修改', () => this.pickThreshold())
      }
      .layoutWeight(1)
    }
    .width('100%')
  }

  @Builder
  sectionHeader(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor($r('app.color.power_secondary'))
      .width('100%')
      .padding({ left: 16, top: 12, bottom: 2 })
  }

  @Builder
  row(icon: Resource, tint: ResourceColor, title: string, value: string, action: () => void) {
    Row({ space: 12 }) {
      this.iconTile(icon, tint, 29)
      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.power_label'))
        .layoutWeight(1)
      Text(value)
        .fontSize(15)
        .fontColor($r('app.color.power_secondary'))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(13)
        .fontColor([$r('app.color.power_tertiary')])
    }
    .width('100%')
    .height(52)
    .padding({ left: 14, right: 14 })
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.power_fill'))
      },
      normal: {
        .backgroundColor(Color.Transparent)
      }
    })
    .onClick(action)
  }

  @Builder
  settings() {
    Column() {
      this.row($r('sys.symbol.bell_fill'), $r('app.color.power_red'), '低电量通知',
        this.notifyOn ? '已开启' : '未开启', () => this.requestNotify())
      Divider().color($r('app.color.power_separator')).strokeWidth(0.5).margin({ left: 55 })
      this.row($r('sys.symbol.square_grid_2x2'), $r('app.color.power_accent'), '添加桌面卡片', '2×2 · 2×4',
        () => this.addCard())
      Divider().color($r('app.color.power_separator')).strokeWidth(0.5).margin({ left: 55 })
      this.row($r('sys.symbol.clock'), $r('app.color.power_green'), '自动查询', '约每 2 小时', () => {
        this.getUIContext().getPromptAction().showToast({ message: '后台由系统择机执行, 卡片也会定时刷新' });
      })
    }
    .width('100%')
    .borderRadius(14)
    .clip(true)
    .backgroundColor($r('app.color.power_card'))
  }

  @Builder
  rebind() {
    Text('重新绑定宿舍')
      .fontSize(16)
      .fontColor($r('app.color.power_red'))
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(52)
      .borderRadius(14)
      .backgroundColor($r('app.color.power_card'))
      .stateStyles({
        pressed: {
          .opacity(0.6)
        },
        normal: {
          .opacity(1)
        }
      })
      .onClick(() => this.openSetup())
  }

  @Builder
  emptyState() {
    Column({ space: 10 }) {
      Image($r('app.media.startIcon'))
        .width(88)
        .height(88)
        .margin({ bottom: 8 })
      Text('绑定你的宿舍')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.power_label'))
      Text('用完美校园帐号登录, 在缴费页选中房间, 看到剩余电量后自动完成绑定')
        .fontSize(15)
        .fontColor($r('app.color.power_secondary'))
        .textAlign(TextAlign.Center)
      Button('开始绑定', { type: ButtonType.Capsule })
        .width('100%')
        .height(50)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.power_accent'))
        .margin({ top: 14 })
        .onClick(() => this.openSetup())
    }
    .width('100%')
    .padding(24)
    .borderRadius(26)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.power_card'))
  }

  build() {
    Navigation(this.pathStack) {
      Refresh({ refreshing: $$this.refreshing }) {
        Scroll(this.scroller) {
          Column({ space: 12 }) {
            if (this.view.configured) {
              this.hero()
              if (this.statusText.length > 0 || this.view.sessionDead) {
                this.alertBanner()
              }
              this.stats()
              this.sectionHeader('提醒与卡片')
              this.settings()
              Blank().height(8)
              this.rebind()
            } else {
              this.emptyState()
            }
            Text('数据来自完美校园云缴费, 仅保存在本机')
              .fontSize(12)
              .fontColor($r('app.color.power_tertiary'))
              .margin({ top: 10 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 40 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .onRefreshing(() => this.query())
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.power_bg'))
    }
    // 标准 Navigation: 内容区排在标题栏下方, 状态栏安全区由系统处理; Free 模式大标题随滚动收起
    .title(this.titleInfo(), {
      backgroundColor: $r('app.color.power_bg'),
      backgroundBlurStyle: BlurStyle.COMPONENT_THICK
    })
    .menus([
      {
        value: '刷新',
        symbolIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise')),
        isEnabled: this.view.configured,
        action: () => this.query()
      }
    ])
    .titleMode(NavigationTitleMode.Free)
    .mode(NavigationMode.Stack)
    .hideToolBar(true)
    .navDestination(this.routes)
    .backgroundColor($r('app.color.power_bg'))
  }
}

import { common, Want } from '@kit.AbilityKit';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { formProvider } from '@kit.FormKit';
import { notificationManager } from '@kit.NotificationKit';
import { HdsNavigation, HdsNavigationAttribute, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { Prefs } from '../service/Prefs';
import { PowerApi, RoomState } from '../service/PowerApi';
import { AlertEval } from '../service/AlertEval';
import { PowerSync } from '../service/PowerSync';
import { PowerLevel, PowerStatus, PowerView } from '../service/PowerStatus';
import { SetupPage } from './Setup';

const THRESHOLDS: string[] = ['5', '10', '15', '20', '30', '50', '80', '100'];

/** 支持沉浸光感(鸿蒙7)的设备用系统材质, 其余设备退回纯色卡片 */
function glassSupported(): boolean {
  try {
    return uiMaterial.isImmersiveMaterialSupported();
  } catch (e) {
    return false;
  }
}

const GLASS: boolean = glassSupported();
const PANEL_MATERIAL: uiMaterial.ImmersiveMaterial | undefined = GLASS
  ? new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR }) : undefined;

/** 内容面板: 光感材质或纯色卡片 */
@Component
struct GlassPanel {
  @BuilderParam content: () => void;
  padValue: number = 16;

  build() {
    if (GLASS) {
      Column() {
        this.content()
      }
      .width('100%')
      .padding(this.padValue)
      .borderRadius(24)
      .systemMaterial(PANEL_MATERIAL)
    } else {
      Column() {
        this.content()
      }
      .width('100%')
      .padding(this.padValue)
      .borderRadius(24)
      .backgroundColor($r('app.color.power_card'))
    }
  }
}

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

  requestNotify(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    notificationManager.requestEnableNotification(ctx).then(() => {
      this.checkNotify();
    }).catch(() => {
      this.checkNotify();
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
        return $r('app.color.power_accent');
    }
  }

  @Builder
  routes(name: string, param: Object) {
    if (name === 'setup') {
      SetupPage()
    }
  }

  @Builder
  hero() {
    GlassPanel({ padValue: 20 }) {
      Stack() {
        Gauge({ value: this.view.percent, min: 0, max: 100 }) {
          Column() {
            Text(PowerStatus.fmtQty(this.view.qty))
              .fontSize(58)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.power_label'))
              .contentTransition(new NumericTextTransition())
            Text('剩余电量 · 度')
              .fontSize(13)
              .fontColor($r('app.color.power_secondary'))
            Row({ space: 4 }) {
              SymbolGlyph(this.view.level === PowerLevel.OK
                ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.exclamationmark_triangle_fill'))
                .fontSize(13)
                .fontColor([this.levelColor(this.view.level)])
              Text(PowerStatus.levelText(this.view.level))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.levelColor(this.view.level))
            }
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .backgroundColor($r('app.color.power_fill'))
            .margin({ top: 10 })
            .visibility(this.view.qty >= 0 ? Visibility.Visible : Visibility.Hidden)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        .startAngle(225)
        .endAngle(135)
        .colors(this.levelColor(this.view.level))
        .strokeWidth(16)
        .indicator(null)
        .width(250)
        .height(250)
      }
      .width('100%')

      Row({ space: 6 }) {
        if (this.querying) {
          LoadingProgress().width(16).height(16).color($r('app.color.power_secondary'))
        }
        Text(this.querying ? '正在查询…' : PowerStatus.fmtTime(this.view.lastAt))
          .fontSize(12)
          .fontColor($r('app.color.power_tertiary'))
      }
      .margin({ top: 4 })

      if (this.statusText.length > 0 || this.view.sessionDead) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
            .fontSize(14)
            .fontColor([$r('app.color.power_red')])
          Text(this.statusText.length > 0 ? this.statusText : '登录已过期, 请重新绑定以恢复查询')
            .fontSize(13)
            .fontColor($r('app.color.power_red'))
            .layoutWeight(1)
          Text('重新登录')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.power_accent'))
            .onClick(() => this.openSetup())
        }
        .width('100%')
        .padding(12)
        .margin({ top: 12 })
        .borderRadius(14)
        .backgroundColor($r('app.color.power_fill'))
      }
    }
  }

  @Builder
  tile(icon: Resource, value: string, unit: string, label: string, action: () => void) {
    Column({ space: 2 }) {
      Row() {
        SymbolGlyph(icon)
          .fontSize(16)
          .fontColor([$r('app.color.power_accent')])
      }
      .width(32)
      .height(32)
      .borderRadius(16)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.power_accent_soft'))
      .margin({ bottom: 8 })

      Row({ space: 2 }) {
        Text(value)
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.power_label'))
        Text(unit)
          .fontSize(12)
          .fontColor($r('app.color.power_secondary'))
          .margin({ bottom: 4 })
      }
      .alignItems(VerticalAlign.Bottom)

      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.power_secondary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .onClick(action)
  }

  @Builder
  stats() {
    Row({ space: 12 }) {
      Column() {
        GlassPanel() {
          this.tile($r('sys.symbol.timer'),
            this.view.daysLeft >= 0 ? String(this.view.daysLeft) : '--', '天',
            this.view.dailyUse > 0 ? `预计可用 · 日均 ${this.view.dailyUse.toFixed(1)} 度` : '预计可用 · 数据积累中',
            () => {})
        }
      }
      .layoutWeight(1)

      Column() {
        GlassPanel() {
          this.tile($r('sys.symbol.bell_fill'), PowerStatus.fmtQty(this.view.threshold), '度',
            '低于此值通知 · 点按修改', () => this.pickThreshold())
        }
      }
      .layoutWeight(1)
    }
    .width('100%')
  }

  @Builder
  row(icon: Resource, title: string, value: string, danger: boolean, action: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([danger ? $r('app.color.power_red') : $r('app.color.power_secondary')])
      Text(title)
        .fontSize(16)
        .fontColor(danger ? $r('app.color.power_red') : $r('app.color.power_label'))
        .layoutWeight(1)
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.power_secondary'))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('app.color.power_tertiary')])
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 12 })
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
    GlassPanel({ padValue: 0 }) {
      Column() {
        this.row($r('sys.symbol.bell_fill'), '低电量通知', this.notifyOn ? '已开启' : '未开启', false,
          () => this.requestNotify())
        Divider().color($r('app.color.power_separator')).margin({ left: 48 })
        this.row($r('sys.symbol.square_grid_2x2'), '添加桌面卡片', '2×2 · 2×4', false, () => this.addCard())
        Divider().color($r('app.color.power_separator')).margin({ left: 48 })
        this.row($r('sys.symbol.clock'), '自动查询', '约每 2 小时', false, () => {
          this.getUIContext().getPromptAction().showToast({ message: '后台由系统择机执行, 卡片也会定时刷新' });
        })
        Divider().color($r('app.color.power_separator')).margin({ left: 48 })
        this.row($r('sys.symbol.arrow_counterclockwise'), '重新绑定宿舍', '', true, () => this.openSetup())
      }
      .borderRadius(24)
      .clip(true)
    }
  }

  @Builder
  emptyState() {
    GlassPanel({ padValue: 24 }) {
      Column({ space: 10 }) {
        Row() {
          SymbolGlyph($r('sys.symbol.bolt_fill'))
            .fontSize(40)
            .fontColor([$r('app.color.power_accent')])
        }
        .width(80)
        .height(80)
        .borderRadius(40)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.power_accent_soft'))
        .margin({ bottom: 6 })

        Text('绑定你的宿舍')
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.power_label'))
        Text('用完美校园帐号登录, 在缴费页选中房间, 看到剩余电量后自动完成绑定')
          .fontSize(14)
          .fontColor($r('app.color.power_secondary'))
          .textAlign(TextAlign.Center)
        Button('开始绑定', { type: ButtonType.Capsule })
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.power_accent'))
          .margin({ top: 12 })
          .onClick(() => this.openSetup())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
  }

  build() {
    HdsNavigation(this.pathStack) {
      Stack({ alignContent: Alignment.Top }) {
        // 顶部暖色光晕, 让光感材质有可透出的底色
        Column()
          .width('100%')
          .height(420)
          .linearGradient({
            angle: 180,
            colors: [[$r('app.color.power_glow'), 0], [$r('app.color.power_bg'), 1]]
          })

        Refresh({ refreshing: $$this.refreshing }) {
          Scroll(this.scroller) {
            Column({ space: 12 }) {
              if (this.view.configured) {
                this.hero()
                this.stats()
                this.settings()
              } else {
                this.emptyState()
              }
              Text('数据来自完美校园云缴费 · 仅保存在本机')
                .fontSize(12)
                .fontColor($r('app.color.power_tertiary'))
                .margin({ top: 8 })
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
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.power_bg'))
    }
    .titleBar({
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.COMMON_BLUR
        }
      },
      content: {
        title: {
          mainTitle: '宿舍电费',
          subTitle: this.view.configured ? (this.view.room.length > 0 ? this.view.room : '已绑定') : '尚未绑定'
        },
        menu: {
          value: [
            {
              content: {
                icon: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise')),
                label: '刷新',
                isEnabled: this.view.configured,
                action: () => this.query()
              }
            }
          ]
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FULL)
    .bindToScrollable([this.scroller])
    .mode(NavigationMode.Stack)
    .hideToolBar(true)
    .navDestination(this.routes)
  }
}

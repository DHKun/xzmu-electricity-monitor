import { notificationManager } from '@kit.NotificationKit';
import BuildProfile from 'BuildProfile';
import { Prefs } from '../service/Prefs';
import { PowerStatus } from '../service/PowerStatus';
import { Credentials } from '../service/Credentials';
import { addCard, DATA_VERSION, pickThreshold, requestNotify } from './Actions';

/** 设置页: 仿系统「设置」的分组圆角列表与彩色圆形图标, 平板上居中限宽 */
@Component
export struct SettingsPage {
  @StorageProp(DATA_VERSION) @Watch('load') dataVersion: number = 0;
  @State notifyOn: boolean = false;
  @State threshold: number = 20;
  @State room: string = '';
  @State autoLoginOn: boolean = false;
  private stack: NavPathStack | null = null;

  aboutToAppear(): void {
    this.load();
  }

  load(): void {
    Prefs.reload();
    this.threshold = Prefs.getThreshold();
    this.room = Prefs.getRoomLabel();
    this.autoLoginOn = Credentials.has();
    this.checkNotify();
  }

  checkNotify(): void {
    notificationManager.isNotificationEnabled().then((on: boolean) => {
      this.notifyOn = on;
    }).catch(() => {});
  }

  /** 最近的同步记录, 用来分辨是没被系统调度、网络失败还是恢复失败 */
  showRunLog(): void {
    Prefs.reload();
    const lines: string[] = Prefs.getRunLog().reverse();
    this.getUIContext().showAlertDialog({
      title: '最近同步记录',
      message: lines.length > 0 ? lines.join('\n') : '暂无记录',
      confirm: { value: '关闭', action: () => {} }
    });
  }

  /** 已开启则确认后关闭并删除保存的密码; 未开启则提示去绑定页勾选 */
  toggleAutoLogin(): void {
    if (!Credentials.has()) {
      this.getUIContext().getPromptAction().showToast({ message: '在重新绑定宿舍时勾选"记住密码"即可开启' });
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '关闭自动续期',
      message: '将删除本机保存的登录密码, 之后会话过期需手动重新登录。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '关闭并删除',
        fontColor: $r('app.color.set_red'),
        action: () => { Credentials.clear(); this.autoLoginOn = false; }
      }
    });
  }

  @Builder
  groupTitle(title: string) {
    Text(title)
      .fontSize(14)
      .fontColor($r('sys.color.font_secondary'))
      .width('100%')
      .padding({ left: 12, top: 20, bottom: 8 })
  }

  @Builder
  icon(symbol: Resource, tint: ResourceColor) {
    Row() {
      SymbolGlyph(symbol)
        .fontSize(17)
        .fontColor([Color.White])
    }
    .width(32)
    .height(32)
    .borderRadius(16)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(tint)
  }

  /** 列表行: 图标 / 标题 / 右侧值 / 箭头 */
  @Builder
  row(symbol: Resource, tint: ResourceColor, title: string, value: string, arrow: boolean, action: () => void) {
    Row({ space: 12 }) {
      this.icon(symbol, tint)
      Text(title)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      Text(value)
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (arrow) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([$r('sys.color.icon_tertiary')])
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 12, right: 12 })
    .borderRadius(16)
    .stateStyles({
      pressed: {
        .backgroundColor($r('sys.color.interactive_pressed'))
      },
      normal: {
        .backgroundColor(Color.Transparent)
      }
    })
    .onClick(action)
  }

  @Builder
  divider() {
    Divider()
      .color($r('sys.color.comp_divider'))
      .strokeWidth(0.5)
      .margin({ left: 56, right: 12 })
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          this.groupTitle('提醒')
          Column() {
            Row({ space: 12 }) {
              this.icon($r('sys.symbol.bell_fill'), $r('app.color.set_red'))
              Column({ space: 2 }) {
                Text('低电量通知')
                  .fontSize(16)
                  .fontColor($r('sys.color.font_primary'))
                Text(this.notifyOn ? '低于阈值时提醒充值' : '未开启, 收不到低电量提醒')
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              // 开关只反映系统授权状态, 点按后交给系统授权框或通知设置页
              Toggle({ type: ToggleType.Switch, isOn: this.notifyOn })
                .hitTestBehavior(HitTestMode.None)
            }
            .width('100%')
            .height(64)
            .padding({ left: 12, right: 12 })
            .onClick(() => requestNotify(this.getUIContext(), this.notifyOn, () => this.checkNotify()))
            this.divider()
            this.row($r('sys.symbol.battery_20percent'), $r('app.color.set_orange'), '提醒阈值',
              `${PowerStatus.fmtQty(this.threshold)} 度`, true,
              () => pickThreshold(this.getUIContext(), this.threshold, () => this.load()))
          }
          .width('100%')
          .padding(4)
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          this.groupTitle('桌面与后台')
          Column() {
            this.row($r('sys.symbol.square_grid_2x2'), $r('app.color.set_blue'), '添加服务卡片', '2×2 · 2×4', true,
              () => addCard(this.getUIContext()))
            this.divider()
            this.row($r('sys.symbol.clock'), $r('app.color.set_green'), '自动查询', '约每 2 小时', false, () => {})
          }
          .width('100%')
          .padding(4)
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          this.groupTitle('宿舍')
          Column() {
            this.row($r('sys.symbol.house_fill'), $r('app.color.set_purple'), '当前房间',
              this.room.length > 0 ? this.room : '未绑定', false, () => {})
            this.divider()
            this.row($r('sys.symbol.arrow_clockwise'), $r('app.color.set_gray'), '重新绑定宿舍', '', true, () => {
              if (this.stack !== null) {
                this.stack.pushPath(new NavPathInfo('setup', ''));
              }
            })
          }
          .width('100%')
          .padding(4)
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          this.groupTitle('账号')
          Column() {
            this.row($r('sys.symbol.arrow_clockwise'), $r('app.color.set_green'), '会话自动续期',
              this.autoLoginOn ? '已开启' : '未开启', true, () => this.toggleAutoLogin())
          }
          .width('100%')
          .padding(4)
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          this.groupTitle('关于')
          Column() {
            this.row($r('sys.symbol.info_circle'), $r('app.color.set_gray'), '版本', BuildProfile.VERSION_NAME, false,
              () => this.showRunLog())
            this.divider()
            this.row($r('sys.symbol.lightbulb'), $r('app.color.set_gray'), '数据来源', '完美校园云缴费', false, () => {})
          }
          .width('100%')
          .padding(4)
          .borderRadius(20)
          .backgroundColor($r('sys.color.comp_background_list_card'))

          Text('读数与登录信息仅保存在本机')
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 16, bottom: 32 })
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .title('设置')
    .backgroundColor($r('sys.color.background_secondary'))
    .onReady((ctx: NavDestinationContext) => {
      this.stack = ctx.pathStack;
    })
  }
}

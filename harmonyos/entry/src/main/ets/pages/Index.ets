import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Prefs } from '../service/Prefs';
import { PowerApi, queryRoomState, RoomState } from '../service/PowerApi';
import { AlertEval } from '../service/AlertEval';

@Entry
@Component
struct Index {
  @State roomLabel: string = '';
  @State balance: string = '--';
  @State threshold: string = '20';
  @State statusText: string = '';
  @State querying: boolean = false;
  private uiCtx: common.UIAbilityContext | null = null;
  private editController: TextInputController = new TextInputController();

  onPageShow(): void {
    this.refreshState();
    this.manualQuery();
  }

  refreshState(): void {
    if (this.uiCtx === null) {
      this.uiCtx = getContext(this) as common.UIAbilityContext;
    }
    this.roomLabel = Prefs.getRoomLabel().length > 0 ? Prefs.getRoomLabel() : '已绑定房间';
    this.threshold = String(Prefs.getThreshold());
    if (!Prefs.getConfigured()) {
      router.pushUrl({ url: 'pages/Setup' }).catch(() => {});
    }
  }

  fmt(v: number): string {
    return Number.isInteger(v) ? String(v) : String(v);
  }

  manualQuery(): void {
    if (this.querying || !Prefs.getConfigured()) {
      return;
    }
    this.querying = true;
    this.statusText = '查询中…';
    const payProId: string = Prefs.getPayProId();
    const roomVerify: string = Prefs.getRoomVerify();
    queryRoomState(payProId, roomVerify, PowerApi.sessionCookie()).then((r: RoomState) => {
      if (r.setCookie.length > 0 && r.setCookie.includes('SESSION=')) {
        Prefs.setCookieSnapshot(r.setCookie);
      }
      if (r.sessionDead) {
        this.statusText = '登录已过期, 请点击下方"重新登录"';
      } else if (r.ok && r.quantity > 0) {
        this.balance = this.fmt(r.quantity);
        this.statusText = '上次查询: ' + new Date().toLocaleTimeString();
        AlertEval.evaluate(r.quantity, r.unit);
      } else {
        this.statusText = `查询失败: ${r.message}`;
      }
      this.querying = false;
    }).catch(() => {
      this.querying = false;
      this.statusText = '查询失败';
    });
  }

  saveThreshold(): void {
    const v: number = parseFloat(this.threshold);
    if (!isNaN(v) && v >= 0) {
      Prefs.setThreshold(v).then(() => {
        this.getUIContext().getPromptAction().showToast({ message: `阈值已保存: ${v}度` });
        AlertEval.reevaluateWithLast();
      });
    }
  }

  build() {
    Scroll() {
      Column({ space: 0 }) {
        Blank().height(56)
        // 大标题
        Text('XZMU 电费')
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.power_label'))
          .width('100%')
          .padding({ left: 20, right: 20 })
          .margin({ top: 16 })
        Text(this.roomLabel)
          .fontSize(15)
          .fontColor($r('app.color.power_secondary'))
          .width('100%')
          .padding({ left: 20, right: 20 })
          .margin({ top: 2 })

        // 余额卡片
        Column() {
          Text(this.balance)
            .fontSize(72)
            .fontWeight(FontWeight.Lighter)
            .fontColor($r('app.color.power_orange'))
          Text('剩余电量(度)')
            .fontSize(13)
            .fontColor($r('app.color.power_secondary'))
            .margin({ top: 4 })
          if (this.querying) {
            LoadingProgress().width(28).height(28).color($r('app.color.power_orange')).margin({ top: 16 })
          }
        }
        .width('100%')
        .margin({ top: 16 })
        .padding(24)
        .borderRadius(16)
        .backgroundColor($r('app.color.power_card'))
        .alignItems(HorizontalAlign.Center)

        Text(this.statusText)
          .fontSize(13)
          .fontColor($r('app.color.power_secondary'))
          .width('100%')
          .padding({ left: 26, top: 8 })

        // 主按钮
        Button('立即查询')
          .width('100%')
          .height(52)
          .margin({ top: 16, left: 20, right: 20 })
          .fontSize(17)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.power_orange'))
          .borderRadius(14)
          .onClick(() => this.manualQuery())

        // 设置分组
        Column() {
          Row() {
            Text('低电量阈值(度)').fontSize(17).fontColor($r('app.color.power_label')).layoutWeight(1)
            TextInput({ text: this.threshold })
              .type(InputType.NUMBER_DECIMAL)
              .width(90)
              .height(40)
              .fontSize(17)
              .textAlign(TextAlign.End)
              .backgroundColor(Color.Transparent)
              .padding(0)
              .onChange((v: string) => {
                this.threshold = v;
                this.saveThreshold();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          Divider().color($r('app.color.power_separator')).strokeWidth(1).margin({ left: 16 })

          Row() {
            Text('自动查询').fontSize(17).fontColor($r('app.color.power_label')).layoutWeight(1)
            Text('每 2 小时').fontSize(17).fontColor($r('app.color.power_secondary'))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        }
        .width('100%')
        .margin({ top: 20, left: 20, right: 20 })
        .borderRadius(16)
        .backgroundColor($r('app.color.power_card'))
        .clip(true)

        // 危险操作
        Column() {
          Button('重新登录 / 重设房间')
            .width('100%')
            .height(48)
            .fontSize(17)
            .fontColor($r('app.color.power_red'))
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              Prefs.setConfigured(false).then(() => router.pushUrl({ url: 'pages/Setup' }));
            })
        }
        .width('100%')
        .margin({ top: 20, left: 20, right: 20 })
        .borderRadius(16)
        .backgroundColor($r('app.color.power_card'))
        .clip(true)

        Text('低于阈值时发送系统通知提醒充值')
          .fontSize(13)
          .fontColor($r('app.color.power_secondary'))
          .width('100%')
          .padding({ left: 26, top: 10, bottom: 30 })

        Blank().height(20)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.power_bg'))
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

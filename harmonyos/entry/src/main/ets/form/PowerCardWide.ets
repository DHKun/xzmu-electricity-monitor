let wideStorage = new LocalStorage();

/** 2×4 卡片: 左侧环形仪表, 右侧状态与刷新 */
@Entry(wideStorage)
@Component
struct PowerCardWide {
  @LocalStorageProp('configured') configured: boolean = false;
  @LocalStorageProp('qty') qty: string = '--';
  @LocalStorageProp('room') room: string = '我的宿舍';
  @LocalStorageProp('level') level: number = 0;
  @LocalStorageProp('pct') pct: number = 0;
  @LocalStorageProp('sub') sub: string = '';
  @LocalStorageProp('time') time: string = '';
  @LocalStorageProp('busy') busy: boolean = false;

  /** 与 PowerLevel 枚举一致: 1 充足 2 偏低 3 不足 */
  levelColor(): ResourceColor {
    if (this.level === 3) {
      return $r('app.color.power_red');
    }
    if (this.level === 2) {
      return $r('app.color.power_orange');
    }
    if (this.level === 1) {
      return $r('app.color.power_green');
    }
    return $r('app.color.power_accent');
  }

  levelText(): string {
    if (this.level === 3) {
      return '电量不足';
    }
    if (this.level === 2) {
      return '电量偏低';
    }
    if (this.level === 1) {
      return '电量充足';
    }
    return '暂无数据';
  }

  @Builder
  unbound() {
    Row({ space: 14 }) {
      SymbolGlyph($r('sys.symbol.house_fill'))
        .fontSize(40)
        .fontColor([$r('app.color.power_accent')])
      Column({ space: 4 }) {
        Text('尚未绑定宿舍')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.power_label'))
        Text('轻点打开 App, 登录后选择房间即可')
          .fontSize(12)
          .fontColor($r('app.color.power_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  bound() {
    Row({ space: 14 }) {
      Gauge({ value: this.pct, min: 0, max: 100 }) {
        Column() {
          Text(this.qty)
            .fontSize(26)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.power_label'))
            .maxLines(1)
          Text('度')
            .fontSize(11)
            .fontColor($r('app.color.power_secondary'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
      .startAngle(225)
      .endAngle(135)
      .colors(this.levelColor())
      .strokeWidth(9)
      .indicator(null)
      .width(110)
      .height(110)

      Column() {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.bolt_fill'))
            .fontSize(14)
            .fontColor([this.levelColor()])
          Text(this.room)
            .fontSize(13)
            .fontColor($r('app.color.power_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')

        Text(this.levelText())
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.levelColor())
          .margin({ top: 8 })
        Text(this.sub)
          .fontSize(12)
          .fontColor($r('app.color.power_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })

        Blank()

        Row() {
          Text(this.time.length > 0 ? `${this.time} 更新` : '')
            .fontSize(11)
            .fontColor($r('app.color.power_tertiary'))
            .layoutWeight(1)
          FormLink({
            action: 'message',
            params: { 'action': 'refresh' }
          }) {
            Row({ space: 4 }) {
              if (this.busy) {
                LoadingProgress()
                  .width(14)
                  .height(14)
                  .color($r('app.color.power_accent'))
              } else {
                SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                  .fontSize(13)
                  .fontColor([$r('app.color.power_accent')])
              }
              Text(this.busy ? '刷新中' : '刷新')
                .fontSize(12)
                .fontColor($r('app.color.power_accent'))
            }
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor($r('app.color.power_accent_soft'))
            .borderRadius(14)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      if (this.configured) {
        this.bound()
      } else {
        this.unbound()
      }
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor($r('app.color.power_card'))
    .linearGradient({
      angle: 120,
      colors: [[$r('app.color.power_glow'), 0], [$r('app.color.power_card'), 0.6]]
    })
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: {}
      });
    })
  }
}

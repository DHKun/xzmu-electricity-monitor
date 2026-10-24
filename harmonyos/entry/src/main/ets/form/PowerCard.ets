let cardStorage = new LocalStorage();

/** 2×2 卡片: 读数 + 进度条 + 预计可用天数, 右上角刷新不拉起 App */
@Entry(cardStorage)
@Component
struct PowerCard {
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
    return $r('app.color.power_gray');
  }

  @Builder
  unbound() {
    Column({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.bolt_fill'))
        .fontSize(32)
        .fontColor([$r('app.color.power_amber')])
      Text('尚未绑定宿舍')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.hero_label'))
      Text('轻点打开 App 绑定')
        .fontSize(11)
        .fontColor($r('app.color.hero_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  bound() {
    Column() {
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.bolt_fill'))
          .fontSize(14)
          .fontColor([$r('app.color.power_amber')])
        Text(this.room)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hero_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        FormLink({
          action: 'message',
          params: { 'action': 'refresh' }
        }) {
          if (this.busy) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color($r('app.color.hero_label'))
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(15)
              .fontColor([$r('app.color.hero_secondary')])
          }
        }
        .width(28)
        .height(28)
      }
      .width('100%')

      Blank()

      Row({ space: 3 }) {
        Text(this.qty)
          .fontSize(38)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.hero_label'))
          .maxLines(1)
        Text('度')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hero_secondary'))
          .margin({ bottom: 7 })
      }
      .alignItems(VerticalAlign.Bottom)

      Progress({ value: this.pct, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(6)
        .color($r('app.color.power_amber'))
        .backgroundColor($r('app.color.hero_fill'))
        .style({ strokeWidth: 6, strokeRadius: 3 })
        .margin({ top: 6 })

      Row({ space: 5 }) {
        Circle()
          .width(6)
          .height(6)
          .fill(this.levelColor())
        Text(this.sub)
          .fontSize(11)
          .fontColor($r('app.color.hero_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.time)
          .fontSize(10)
          .fontColor($r('app.color.hero_tertiary'))
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
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
    .linearGradient({
      angle: 135,
      colors: [[$r('app.color.hero_start'), 0], [$r('app.color.hero_end'), 1]]
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

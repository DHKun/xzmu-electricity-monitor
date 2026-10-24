let wideStorage = new LocalStorage();

/** 2×4 卡片: 左侧圆环, 右侧状态与刷新 */
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

  /** 与 App 首页同一套天空渐变, 随电量变化 */
  skyTop(): ResourceColor {
    if (this.level === 3) {
      return $r('app.color.sky_low_top');
    }
    if (this.level === 2) {
      return $r('app.color.sky_warn_top');
    }
    if (this.level === 1) {
      return $r('app.color.sky_ok_top');
    }
    return $r('app.color.sky_none_top');
  }

  skyBottom(): ResourceColor {
    if (this.level === 3) {
      return $r('app.color.sky_low_bottom');
    }
    if (this.level === 2) {
      return $r('app.color.sky_warn_bottom');
    }
    if (this.level === 1) {
      return $r('app.color.sky_ok_bottom');
    }
    return $r('app.color.sky_none_bottom');
  }

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
      SymbolGlyph($r('sys.symbol.bolt_fill'))
        .fontSize(44)
        .fontColor([$r('app.color.power_amber')])
      Column({ space: 4 }) {
        Text('尚未绑定宿舍')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_sky'))
        Text('轻点打开 App, 登录后选择房间即可')
          .fontSize(12)
          .fontColor($r('app.color.on_sky_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  bound() {
    Row({ space: 16 }) {
      Stack() {
        Progress({ value: this.pct, total: 100, type: ProgressType.Ring })
          .width(108)
          .height(108)
          .color($r('app.color.on_sky'))
          .backgroundColor($r('app.color.glass_track'))
          .style({ strokeWidth: 10 })
        Column() {
          Text(this.qty)
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_sky'))
            .maxLines(1)
          Text('度')
            .fontSize(11)
            .fontColor($r('app.color.on_sky_secondary'))
        }
      }

      Column() {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.bolt_fill'))
            .fontSize(14)
            .fontColor([$r('app.color.power_amber')])
          Text(this.room)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_sky_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 6 }) {
          Circle()
            .width(8)
            .height(8)
            .fill(this.levelColor())
          Text(this.levelText())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_sky'))
        }
        .margin({ top: 10 })
        Text(this.sub)
          .fontSize(12)
          .fontColor($r('app.color.on_sky_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })

        Blank()

        Row() {
          Text(this.time.length > 0 ? `${this.time} 更新` : '')
            .fontSize(11)
            .fontColor($r('app.color.on_sky_tertiary'))
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
                  .color($r('app.color.on_sky'))
              } else {
                SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                  .fontSize(12)
                  .fontColor([$r('app.color.on_sky')])
              }
              Text(this.busy ? '刷新中' : '刷新')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.on_sky'))
            }
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor($r('app.color.glass'))
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
    .padding(16)
    .linearGradient({
      angle: 180,
      colors: [[this.skyTop(), 0], [this.skyBottom(), 1]]
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

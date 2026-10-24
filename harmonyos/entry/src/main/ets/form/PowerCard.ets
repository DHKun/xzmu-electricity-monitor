let storage = new LocalStorage();

@Entry(storage)
@Component
struct PowerCard {
  @LocalStorageProp('qty') qty: string = '--';
  @LocalStorageProp('room') room: string = '未绑定';
  @LocalStorageProp('time') time: string = '';
  @LocalStorageProp('low') low: boolean = false;

  build() {
    Column({ space: 2 }) {
      Text(this.room)
        .fontSize(12)
        .fontColor($r('app.color.power_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text(`${this.qty} 度`)
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.low ? $r('app.color.power_red') : $r('app.color.power_orange'))

      Row() {
        Text(this.time)
          .fontSize(10)
          .fontColor($r('app.color.power_secondary'))
          .layoutWeight(1)
          .maxLines(1)
        // 互动卡片: 不拉起 App, 卡片上直接刷新
        FormLink({
          action: 'call',
          abilityName: 'EntryFormAbility',
          params: { 'method': 'refresh' }
        }) {
          Text('刷新')
            .fontSize(11)
            .fontColor(Color.White)
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .backgroundColor($r('app.color.power_orange'))
            .borderRadius(10)
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor($r('app.color.power_card'))
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: {}
      });
    })
  }
}

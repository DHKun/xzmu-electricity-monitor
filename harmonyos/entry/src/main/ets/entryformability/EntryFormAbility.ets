import { FormExtensionAbility, formBindingData, formProvider, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from '../service/Prefs';
import { PowerApi, queryRoomState, RoomState } from '../service/PowerApi';

class CardData {
  qty: string = '--';
  room: string = '';
  time: string = '';
  low: boolean = false;
}

const TAG: string = 'EntryFormAbility';
const DOMAIN: number = 0x0000;

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = want.parameters !== undefined && want.parameters['ohos.extra.param.key.form_identity'] !== undefined
      ? want.parameters['ohos.extra.param.key.form_identity'] as string : '';
    hilog.info(DOMAIN, TAG, 'onAddForm %{public}s', formId);
    if (formId.length > 0) {
      Prefs.addFormId(formId).catch(() => {});
    }
    // 首次添加: 先给静态数据, 异步查一次再刷
    const card: CardData = new CardData();
    card.qty = Prefs.getLastQty() >= 0 ? String(Prefs.getLastQty()) : '--';
    card.room = Prefs.getConfigured() ? Prefs.getRoomLabel() : '未绑定';
    card.time = '';
    card.low = Prefs.getLastQty() >= 0 && Prefs.getLastQty() < Prefs.getThreshold();
    const data: formBindingData.FormBindingData = formBindingData.createFormBindingData(card);
    this.refreshCard(formId);
    return data;
  }

  /** 互动卡片"刷新"等事件 */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, 'onFormEvent %{public}s %{public}s', formId, message);
    this.refreshCard(formId);
  }

  onUpdateForm(formId: string): void {
    this.refreshCard(formId);
  }

  private refreshCard(formId: string): void {
    if (!Prefs.getConfigured()) {
      return;
    }
    const payProId: string = Prefs.getPayProId();
    const roomVerify: string = Prefs.getRoomVerify();
    // 扩展进程无 WebView, 直接用快照 Cookie
    const cookie: string = Prefs.getCookieSnapshot();
    queryRoomState(payProId, roomVerify, cookie).then((r: RoomState) => {
      if (!r.ok || r.quantity <= 0) {
        return;
      }
      Prefs.setLastQty(r.quantity).then(() => {
        const time: string = new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
        const card: CardData = new CardData();
        card.qty = String(r.quantity);
        card.room = r.roomLabel.length > 0 ? r.roomLabel : Prefs.getRoomLabel();
        card.time = time;
        card.low = r.quantity < Prefs.getThreshold();
        const data: formBindingData.FormBindingData = formBindingData.createFormBindingData(card);
        formProvider.updateForm(formId, data).catch(() => {});
      });
    }).catch(() => {});
  }

  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onRemoveForm %{public}s', formId);
    Prefs.removeFormId(formId).catch(() => {});
  }
}

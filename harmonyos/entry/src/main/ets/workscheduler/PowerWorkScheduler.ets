import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from '../service/Prefs';
import { PowerApi, queryRoomState, RoomState } from '../service/PowerApi';
import { formProvider, formBindingData } from '@kit.FormKit';

class CardData {
  qty: string = '--';
  room: string = '';
  time: string = '';
  low: boolean = false;
}

const TAG: string = 'PowerWorkScheduler';
const DOMAIN: number = 0x0000;

export default class PowerWorkScheduler extends WorkSchedulerExtensionAbility {
  onWorkStart(workInfo: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, TAG, 'onWorkStart');
    if (!Prefs.getConfigured()) {
      return;
    }
    // 扩展进程无 WebView, 用快照 Cookie(每次成功查询后同步)
    const cookie: string = Prefs.getCookieSnapshot();
    queryRoomState(Prefs.getPayProId(), Prefs.getRoomVerify(), cookie).then((r: RoomState) => {
      if (r.setCookie.length > 0 && r.setCookie.includes('SESSION=')) {
        Prefs.setCookieSnapshot(r.setCookie);
      }
      if (r.sessionDead) {
        this.notify('电费监控: 登录已过期', '打开 App 重新登录一次即可恢复');
        return;
      }
      if (!r.ok || r.quantity <= 0) {
        return;
      }
      const threshold: number = Prefs.getThreshold();
      Prefs.setLastQty(r.quantity).then(() => {
        this.updateAllCards(r.quantity, r.roomLabel);
        if (r.quantity < threshold) {
          if (!Prefs.isAlerted()) {
            this.notify(`⚠️ 电费不足! ${r.roomLabel} 剩余 ${r.quantity}${r.unit}`,
              `低于阈值 ${threshold}${r.unit}, 请尽快充值`);
            Prefs.setAlerted(true);
          }
        } else {
          if (Prefs.isAlerted()) {
            this.notify(`电费已恢复: ${r.quantity}${r.unit}`, '回到阈值以上');
          }
          Prefs.setAlerted(false);
        }
      });
    }).catch(() => {});
  }

  onWorkStop(workInfo: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, TAG, 'onWorkStop');
  }

  private notify(title: string, text: string): void {
    const request: notificationManager.NotificationRequest = {
      id: 1001,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: title, text: text, additionalText: 'XZMU电费' }
      }
    };
    notificationManager.publish(request).catch(() => {});
  }

  /** 查询结果同步到桌面服务卡片 */
  private updateAllCards(qty: number, roomLabel: string): void {
    const time: string = new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
    const card: CardData = new CardData();
    card.qty = String(qty);
    card.room = roomLabel.length > 0 ? roomLabel : Prefs.getRoomLabel();
    card.time = time;
    card.low = qty < Prefs.getThreshold();
    const data: formBindingData.FormBindingData = formBindingData.createFormBindingData(card);
    const ids: string[] = Prefs.getFormIds();
    for (let i = 0; i < ids.length; i++) {
      formProvider.updateForm(ids[i], data).catch(() => {});
    }
  }
}

import { notificationManager } from '@kit.NotificationKit';
import { Prefs } from './Prefs';

const ID_ALERT: number = 1001;
const ID_LOGIN: number = 1003;

/** 阈值评估: 手动查询、修改阈值、后台轮询三条路径共用 */
export class AlertEval {

  /** 读数已落盘, 这里只负责提醒; 返回 true 表示低电量告警没能发出: 告警状态保持未发, 下次评估会再发 */
  static async evaluate(quantity: number, unit: string): Promise<boolean> {
    const threshold: number = Prefs.getThreshold();
    if (quantity < threshold) {
      if (Prefs.isAlerted()) {
        return false;
      }
      const label: string = Prefs.getRoomLabel();
      const posted: boolean = await AlertNotify.publish(`⚠️ 电费不足! ${label} 剩余 ${quantity}${unit}`,
        `低于阈值 ${threshold}${unit}, 请尽快充值`);
      if (posted) {
        await Prefs.setAlerted(true);
      }
      return !posted;
    }
    if (Prefs.isAlerted()) {
      await AlertNotify.publish(`电费已恢复: ${quantity}${unit}`, '回到阈值以上');
      await Prefs.setAlerted(false);
    }
    return false;
  }

  /** 阈值被修改后, 用最近一次电量立即重评 */
  static async reevaluateWithLast(): Promise<void> {
    const last: number = Prefs.getLastQty();
    if (last >= 0) {
      await AlertEval.evaluate(last, '度');
    }
  }
}

export class AlertNotify {
  /** 返回是否已交给系统发布; 通知开关未开时发布会失败 */
  static async publish(title: string, text: string, id: number = ID_ALERT): Promise<boolean> {
    try {
      const request: notificationManager.NotificationRequest = {
        id: id,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: '民大电费'
          }
        }
      };
      await notificationManager.publish(request);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 需要用户手动登录 */
  static login(): Promise<boolean> {
    return AlertNotify.publish('电费监控: 需要重新登录', '自动登录未能完成, 打开 App 重新登录后即可恢复监控', ID_LOGIN);
  }

  static async cancelLogin(): Promise<void> {
    try {
      await notificationManager.cancel(ID_LOGIN);
    } catch (e) {
      // 本就没有这条通知时忽略
    }
  }
}

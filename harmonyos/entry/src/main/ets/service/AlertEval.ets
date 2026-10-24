import { notificationManager } from '@kit.NotificationKit';
import { Prefs } from './Prefs';

/** 阈值评估: 手动查询、修改阈值、后台轮询三条路径共用 */
export class AlertEval {

  /** 只负责提醒; 读数由 Prefs.recordReading 落盘 */
  static async evaluate(quantity: number, unit: string): Promise<void> {
    const threshold: number = Prefs.getThreshold();
    if (quantity < threshold) {
      if (!Prefs.isAlerted()) {
        const label: string = Prefs.getRoomLabel();
        AlertNotify.publish(`⚠️ 电费不足! ${label} 剩余 ${quantity}${unit}`,
          `低于阈值 ${threshold}${unit}, 请尽快充值`);
        await Prefs.setAlerted(true);
      }
    } else {
      if (Prefs.isAlerted()) {
        AlertNotify.publish(`电费已恢复: ${quantity}${unit}`, '回到阈值以上');
        await Prefs.setAlerted(false);
      }
    }
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
  static async publish(title: string, text: string): Promise<void> {
    try {
      const request: notificationManager.NotificationRequest = {
        id: 1001,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: 'XZMU电费'
          }
        }
      };
      await notificationManager.publish(request);
    } catch (e) {
      // 通知开关未开时忽略, 下个周期再试
    }
  }
}

import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from '../service/Prefs';
import { KitTransport } from '../service/HttpClient';
import { PowerSync } from '../service/PowerSync';
import { Trigger } from '../service/SyncEngine';

const TAG: string = 'PowerWorkScheduler';
const DOMAIN: number = 0x0000;

export default class PowerWorkScheduler extends WorkSchedulerExtensionAbility {
  private stopped: boolean = false;
  private http: KitTransport = new KitTransport();

  onWorkStart(workInfo: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, TAG, 'onWorkStart');
    this.stopped = false;
    // 后台任务同样是独立进程
    Prefs.init(this.context);
    // 查询、认证恢复、通知与卡片刷新都在 PowerSync 里
    PowerSync.sync(Trigger.PERIODIC, () => this.stopped, () => {}, this.http).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'sync failed: %{public}s', e.message);
    });
  }

  /** 系统要收回执行机会: 中断请求, 已取消的一轮不再提交结果 */
  onWorkStop(workInfo: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, TAG, 'onWorkStop');
    this.stopped = true;
    this.http.abort();
  }
}

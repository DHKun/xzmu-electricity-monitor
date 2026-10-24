import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from '../service/Prefs';
import { PowerSync } from '../service/PowerSync';

const TAG: string = 'PowerWorkScheduler';
const DOMAIN: number = 0x0000;

export default class PowerWorkScheduler extends WorkSchedulerExtensionAbility {
  onWorkStart(workInfo: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, TAG, 'onWorkStart');
    // 后台任务同样是独立进程
    Prefs.init(this.context);
    // 无 WebView, 用快照 Cookie; 通知与卡片刷新都在 PowerSync 里
    PowerSync.syncNow('').catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'sync failed: %{public}s', e.message);
    });
  }

  onWorkStop(workInfo: workScheduler.WorkInfo): void {
    hilog.info(DOMAIN, TAG, 'onWorkStop');
  }
}

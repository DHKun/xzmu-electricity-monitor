import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { Prefs } from '../service/Prefs';
import { Credentials, CredData } from '../service/Credentials';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { webview } from '@kit.ArkWeb';
import BuildProfile from 'BuildProfile';

const DOMAIN: number = 0x0000;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    Prefs.init(this.context);
    // 调试构建: aa start ... --pb xzmu.demo true 写入示例数据
    if (BuildProfile.DEBUG && want.parameters !== undefined && want.parameters['xzmu.demo'] === true) {
      Prefs.seedDemo().catch(() => {});
    }
    if (BuildProfile.DEBUG && want.parameters !== undefined && want.parameters['xzmu.democreds'] === true) {
      const c: CredData = new CredData();
      c.type = 'wx';
      c.username = 'demo_user';
      c.password = 'demo_pass';
      Credentials.save(c);
    }
    // 首页要从 WebCookieManager 取实时会话, 内核须先初始化
    try {
      webview.WebviewController.initializeWebEngine();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'initializeWebEngine failed: %{public}s', String(e));
    }
    this.schedulePeriodicWork();
  }

  /** 后台周期查询(WorkScheduler, 系统择机执行) */
  private schedulePeriodicWork(): void {
    try {
      const workInfo: workScheduler.WorkInfo = {
        workId: 100,
        bundleName: 'io.github.dhkun.xzmupower',
        abilityName: 'PowerWorkScheduler',
        isRepeat: true,
        isPersisted: true,
        repeatCycleTime: 2 * 60 * 60 * 1000
      };
      workScheduler.startWork(workInfo);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'startWork failed: %{public}s', String(e));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      // 不设全屏布局: ArkUI 自动避让状态栏, 首页天空背景用 expandSafeArea 延伸到状态栏下
    });
  }
}

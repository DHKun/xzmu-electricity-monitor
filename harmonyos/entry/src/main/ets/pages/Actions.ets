import { common, Want } from '@kit.AbilityKit';
import { formProvider } from '@kit.FormKit';
import { notificationManager } from '@kit.NotificationKit';
import { Prefs } from '../service/Prefs';
import { AlertEval } from '../service/AlertEval';
import { CardSync } from '../service/PowerSync';

export const DATA_VERSION: string = 'dataVersion';
export const THRESHOLDS: string[] = ['5', '10', '15', '20', '30', '50', '80', '100'];

/** 通知首页等页面重新读取存储 */
export function bumpData(): void {
  AppStorage.setOrCreate<number>(DATA_VERSION, Date.now());
}

function abilityContext(ui: UIContext): common.UIAbilityContext {
  return ui.getHostContext() as common.UIAbilityContext;
}

/**
 * 未授权时先弹系统授权框; 被拒绝过或系统不再弹框时 requestEnableNotification 会直接失败,
 * 这时跳到本应用的通知设置页. 已开启时直接进设置页, 方便关闭.
 */
export function requestNotify(ui: UIContext, enabled: boolean, done: () => void): void {
  const ctx: common.UIAbilityContext = abilityContext(ui);
  if (enabled) {
    openNotifySettings(ui, done);
    return;
  }
  notificationManager.requestEnableNotification(ctx).then(() => {
    done();
  }).catch(() => {
    openNotifySettings(ui, done);
  });
}

function openNotifySettings(ui: UIContext, done: () => void): void {
  notificationManager.openNotificationSettings(abilityContext(ui)).then(() => {
    done();
  }).catch(() => {
    ui.getPromptAction().showToast({ message: '请在 设置 → 通知和状态栏 中允许民大电费通知' });
    done();
  });
}

export function pickThreshold(ui: UIContext, current: number, done: () => void): void {
  const idx: number = THRESHOLDS.indexOf(String(current));
  ui.showTextPickerDialog({
    range: THRESHOLDS.map((t: string) => `${t} 度`),
    selected: idx >= 0 ? idx : 3,
    onAccept: (v: TextPickerResult) => {
      const i: number = typeof v.index === 'number' ? v.index : 3;
      Prefs.setThreshold(Number(THRESHOLDS[i])).then(() => {
        AlertEval.reevaluateWithLast();
        CardSync.pushAll(false);
        bumpData();
        done();
      });
    }
  });
}

/** 拉起系统"添加卡片"面板 */
export function addCard(ui: UIContext): void {
  const want: Want = {
    bundleName: 'io.github.dhkun.xzmupower',
    abilityName: 'EntryFormAbility',
    parameters: {
      'ohos.extra.param.key.form_dimension': 2,
      'ohos.extra.param.key.form_name': 'PowerCard',
      'ohos.extra.param.key.module_name': 'entry'
    }
  };
  try {
    formProvider.openFormManager(want);
  } catch (e) {
    ui.getPromptAction().showToast({ message: '请在桌面双指捏合 → 服务卡片中添加' });
  }
}

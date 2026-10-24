import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from '../service/Prefs';
import { CardData, CardSync, PowerSync } from '../service/PowerSync';

const TAG: string = 'EntryFormAbility';
const DOMAIN: number = 0x0000;
/** 卡片刷新节流: 系统定时刷新或刚添加时, 10 分钟内查过就不再打接口 */
const FRESH_MS: number = 10 * 60 * 1000;

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    // 卡片进程独立于 App, 必须自己初始化存储并读最新数据
    Prefs.init(this.context);
    const params: Record<string, Object> | undefined = want.parameters;
    const formId: string = params !== undefined && params[formInfo.FormParam.IDENTITY_KEY] !== undefined
      ? params[formInfo.FormParam.IDENTITY_KEY] as string : '';
    hilog.info(DOMAIN, TAG, 'onAddForm %{public}s configured=%{public}s', formId, String(Prefs.getConfigured()));
    if (formId.length > 0) {
      Prefs.addFormId(formId).catch(() => {});
    }
    const card: CardData = CardSync.build(false);
    if (Prefs.getConfigured() && Date.now() - Prefs.getLastAt() > FRESH_MS) {
      this.refresh();
    }
    return formBindingData.createFormBindingData(card);
  }

  /** 互动卡片: 卡片上的刷新按钮(FormLink message) */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, 'onFormEvent %{public}s %{public}s', formId, message);
    Prefs.init(this.context);
    if (!Prefs.getConfigured()) {
      CardSync.pushAll(false);
      return;
    }
    CardSync.pushAll(true);
    this.refresh();
  }

  onUpdateForm(formId: string): void {
    Prefs.init(this.context);
    if (Prefs.getFormIds().indexOf(formId) < 0) {
      Prefs.addFormId(formId).catch(() => {});
    }
    if (Prefs.getConfigured() && Date.now() - Prefs.getLastAt() > FRESH_MS) {
      this.refresh();
    } else {
      CardSync.push(formId, CardSync.build(false));
    }
  }

  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onRemoveForm %{public}s', formId);
    Prefs.init(this.context);
    Prefs.removeFormId(formId).catch(() => {});
  }

  /** 卡片进程拿不到 WebView 会话, 用快照 Cookie; 结果由 PowerSync 推到所有卡片 */
  private refresh(): void {
    PowerSync.syncNow('').catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'sync failed: %{public}s', e.message);
      CardSync.pushAll(false);
    });
  }
}

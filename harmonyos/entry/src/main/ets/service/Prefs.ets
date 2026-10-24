import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE: string = 'config';

export class Prefs {
  private static store: preferences.Preferences | null = null;

  static async init(ctx: common.UIAbilityContext | common.ExtensionContext): Promise<void> {
    Prefs.store = await preferences.getPreferences(ctx, STORE);
  }

  private static sp(): preferences.Preferences {
    if (!Prefs.store) {
      throw new Error('Prefs not initialized');
    }
    return Prefs.store;
  }

  static getConfigured(): boolean {
    return Prefs.sp().getSync('configured', false) as boolean;
  }

  static async setConfigured(v: boolean): Promise<void> {
    await Prefs.sp().put('configured', v);
    await Prefs.sp().flush();
  }

  static getPayProId(): string {
    return Prefs.sp().getSync('payProId', '') as string;
  }

  static getRoomVerify(): string {
    return Prefs.sp().getSync('roomVerify', '') as string;
  }

  static getRoomLabel(): string {
    return Prefs.sp().getSync('roomLabel', '') as string;
  }

  static getThreshold(): number {
    return Prefs.sp().getSync('threshold', 20.0) as number;
  }

  static getCookieSnapshot(): string {
    return Prefs.sp().getSync('cookieSnapshot', '') as string;
  }

  static getLastQty(): number {
    return Prefs.sp().getSync('lastQty', -1.0) as number;
  }

  static isAlerted(): boolean {
    return Prefs.sp().getSync('alerted', false) as boolean;
  }

  static getFormIds(): string[] {
    const raw: string = Prefs.sp().getSync('formIds', '') as string;
    return raw.length > 0 ? raw.split(',') : [];
  }

  static async addFormId(formId: string): Promise<void> {
    const ids: string[] = Prefs.getFormIds();
    if (!ids.includes(formId)) {
      ids.push(formId);
      await Prefs.sp().put('formIds', ids.join(','));
      await Prefs.sp().flush();
    }
  }

  static async removeFormId(formId: string): Promise<void> {
    const ids: string[] = Prefs.getFormIds().filter((id: string) => id !== formId);
    await Prefs.sp().put('formIds', ids.join(','));
    await Prefs.sp().flush();
  }

  static async saveBinding(payProId: string, roomVerify: string, roomLabel: string,
                           cookie: string, qty: number): Promise<void> {
    const sp = Prefs.sp();
    await sp.put('payProId', payProId);
    await sp.put('roomVerify', roomVerify);
    await sp.put('roomLabel', roomLabel);
    await sp.put('cookieSnapshot', cookie);
    await sp.put('lastQty', qty);
    await sp.put('configured', true);
    await sp.flush();
  }

  static async setThreshold(v: number): Promise<void> {
    await Prefs.sp().put('threshold', v);
    await Prefs.sp().flush();
  }

  static async setCookieSnapshot(v: string): Promise<void> {
    if (v.length > 0) {
      await Prefs.sp().put('cookieSnapshot', v);
      await Prefs.sp().flush();
    }
  }

  static async setLastQty(v: number): Promise<void> {
    await Prefs.sp().put('lastQty', v);
    await Prefs.sp().flush();
  }

  static async setAlerted(v: boolean): Promise<void> {
    await Prefs.sp().put('alerted', v);
    await Prefs.sp().flush();
  }
}

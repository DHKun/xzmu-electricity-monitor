import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';

/**
 * 登录凭据的本机安全存储, 用于会话过期后静默重新登录。
 *
 * 用系统资产服务(AssetStore)保存, 由系统负责加密, 仅本应用可读, 不上传任何服务器。
 */
const ALIAS: string = 'xzmu_creds';

export class CredData {
  type: string = 'wx';
  username: string = '';
  password: string = '';
  customerCode: string = '';
  outid: string = '';
}

export class Credentials {
  private static aliasBytes(): Uint8Array {
    return new util.TextEncoder().encodeInto(ALIAS);
  }

  static has(): boolean {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, Credentials.aliasBytes());
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
      const res: Array<asset.AssetMap> = asset.querySync(query);
      return res.length > 0;
    } catch (e) {
      return false;
    }
  }

  static load(): CredData | null {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, Credentials.aliasBytes());
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const res: Array<asset.AssetMap> = asset.querySync(query);
      if (res.length === 0) {
        return null;
      }
      const secret: Uint8Array = res[0].get(asset.Tag.SECRET) as Uint8Array;
      const json: string = util.TextDecoder.create('utf-8').decodeToString(secret);
      return JSON.parse(json) as CredData;
    } catch (e) {
      return null;
    }
  }

  static save(c: CredData): void {
    if (c.password.length === 0) {
      return;
    }
    const secret: Uint8Array = new util.TextEncoder().encodeInto(JSON.stringify(c));
    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.ALIAS, Credentials.aliasBytes());
    attr.set(asset.Tag.SECRET, secret);
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attr.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try {
      asset.addSync(attr);
    } catch (e) {
      // 资产服务不可用时静默放弃, 自动续期不可用而已
    }
  }

  /** 关闭自动续期并抹掉保存的密码 */
  static clear(): void {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, Credentials.aliasBytes());
      asset.removeSync(query);
    } catch (e) {
      // 本就不存在时忽略
    }
  }
}

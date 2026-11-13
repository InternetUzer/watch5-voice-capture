import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export interface ServerConfig { endpoint: string; key: string; }

export class SecureConfig {
  private static alias(): Uint8Array { return new util.TextEncoder().encodeInto('watch5-server-v2'); }
  static async load(): Promise<ServerConfig | undefined> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, SecureConfig.alias()); query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const values = await asset.query(query);
      if (values.length === 0) return undefined;
      const bytes = values[0].get(asset.Tag.SECRET) as Uint8Array;
      return JSON.parse(util.TextDecoder.create('utf-8').decodeWithStream(bytes)) as ServerConfig;
    } catch (error) {
      if ((error as BusinessError).code === 24000002) return undefined;
      throw new Error('Защищённое хранилище недоступно');
    }
  }
  static async save(config: ServerConfig): Promise<void> {
    if (!/^https:\/\/[^/?#]+\/v1\/recordings$/.test(config.endpoint) || !config.key.trim()) {
      throw new Error('Укажи HTTPS-адрес API и ключ');
    }
    const bytes = new util.TextEncoder().encodeInto(JSON.stringify(config));
    if (bytes.byteLength > 1024) throw new Error('Слишком длинные настройки');
    const query: asset.AssetMap = new Map(); query.set(asset.Tag.ALIAS, SecureConfig.alias());
    const update: asset.AssetMap = new Map(); update.set(asset.Tag.SECRET, bytes);
    try { await asset.update(query, update); }
    catch (error) {
      if ((error as BusinessError).code !== 24000002) throw new Error('Не удалось сохранить ключ');
      update.set(asset.Tag.ALIAS, SecureConfig.alias());
      update.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      await asset.add(update);
    }
  }
}

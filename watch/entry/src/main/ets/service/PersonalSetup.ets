import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { SecureConfig, ServerConfig } from './SecureConfig';

interface PersonalProfile {
  version: number;
  id: string;
  endpoint: string;
  key: string;
  phoneBundle: string;
  phoneFingerprint: string;
}

/** Optional, ignored rawfile for a private HAP. Its key is extractable from the HAP.
 * Import once per profile ID, before configuring the uploader or Wear Engine.
 * Ordinary builds have no rawfile and keep the manual setup flow unchanged.
 */
export class PersonalSetup {
  static parse(text: string): PersonalProfile {
    try {
      if (text.length > 4096) throw new Error('Invalid profile');
      const profile = JSON.parse(text) as PersonalProfile;
      if (!profile || profile.version !== 1 || typeof profile.id !== 'string' ||
        !/^[a-f0-9-]{36}$/.test(profile.id) ||
        profile.endpoint !== 'https://voice.metalcarcase.ru/v1/recordings' ||
        typeof profile.key !== 'string' || profile.key.length < 16 || profile.key.length > 512 ||
        !/^[\x21-\x7e]+$/.test(profile.key) ||
        profile.phoneBundle !== 'ru.technadzor.app' ||
        typeof profile.phoneFingerprint !== 'string' || !/^[A-F0-9]{64}$/.test(profile.phoneFingerprint)) {
        throw new Error('Invalid profile');
      }
      return profile;
    } catch (_) {
      // Never propagate JSON errors that might include the input key.
      throw new Error('Личные настройки повреждены · пересоздай файл настройки');
    }
  }

  static async apply(context: common.Context, pref: preferences.Preferences, force: boolean = false): Promise<boolean> {
    let bytes: Uint8Array;
    try {
      bytes = await context.resourceManager.getRawFileContent('personal-setup.json');
    } catch (error) {
      if ((error as BusinessError).code === 9001005) return false;
      throw new Error('Не удалось прочитать личные настройки');
    }
    if (bytes.byteLength > 4096) throw new Error('Личные настройки слишком велики');
    const profile = PersonalSetup.parse(util.TextDecoder.create('utf-8').decodeWithStream(bytes));
    if (!force && await pref.get('personalSetupId', '') === profile.id) return false;
    const config: ServerConfig = { endpoint: profile.endpoint, key: profile.key };
    await SecureConfig.save(config);
    await pref.put('phoneBundle', profile.phoneBundle);
    await pref.put('phoneFingerprint', profile.phoneFingerprint);
    // Commit the marker only after both configuration destinations accepted data.
    await pref.put('personalSetupId', profile.id);
    await pref.flush();
    return true;
  }
}

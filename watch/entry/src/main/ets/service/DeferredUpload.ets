import { workScheduler } from '@kit.BackgroundTasksKit';

/** OS-controlled retry after the UI process stops; this never starts a microphone. */
export class DeferredUpload {
  static readonly work: workScheduler.WorkInfo = {
    workId: 51, bundleName: 'com.example.watch5voicecapture', abilityName: 'UploadWorker',
    networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
    isRepeat: true, repeatCycleTime: 2 * 60 * 60 * 1000, isPersisted: true
  };
  static async ensure(): Promise<void> {
    if (!canIUse('SystemCapability.ResourceSchedule.WorkScheduler')) return;
    try { await workScheduler.getWorkStatus(51); }
    catch (_) { try { workScheduler.startWork(DeferredUpload.work); } catch (_) {} }
  }
}

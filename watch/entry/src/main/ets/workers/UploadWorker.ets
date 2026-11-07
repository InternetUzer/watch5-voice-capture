import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { SecureConfig } from '../service/SecureConfig';
import { Uploader } from '../service/Uploader';

export default class UploadWorker extends WorkSchedulerExtensionAbility {
  private uploader?: Uploader;
  private cancelled: boolean = false;
  onWorkStart(work: workScheduler.WorkInfo): void {
    if (work.workId !== 51) return;
    this.cancelled = false;
    void this.run();
  }
  private async run(): Promise<void> {
    try {
      const config = await SecureConfig.load();
      if (!config || this.cancelled) return;
      this.uploader = new Uploader();
      this.uploader.initialize(this.context);
      this.uploader.configure(config);
    } catch (_) { /* Durable files remain queued for a later OS slot or app launch. */ }
  }
  onWorkStop(_work: workScheduler.WorkInfo): void {
    this.cancelled = true; this.uploader?.close(); this.uploader = undefined;
  }
}

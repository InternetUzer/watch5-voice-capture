import { audio } from '@kit.AudioKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SoundGate } from './SoundGate';
import { WavWriter } from './WavWriter';

export class WatchRecorder {
  private static instance: WatchRecorder = new WatchRecorder();
  static getInstance(): WatchRecorder { return WatchRecorder.instance; }
  private context?: common.UIAbilityContext;
  private capturer?: audio.AudioCapturer;
  private gate: SoundGate = new SoundGate();
  private prior: ArrayBuffer[] = [];
  private priorBytes: number = 0;
  private writer?: WavWriter;
  private running: boolean = false;
  private writeQueue: ArrayBuffer[] = [];
  private draining: boolean = false;
  private lastError: string = '';
  private backgroundActive: boolean = false;
  private fileCount: number = 0;
  private readonly preRollBytes: number = 16000 * 2 * 3;
  private readonly maxClipBytes: number = 16000 * 2 * 60 * 3;

  setContext(context: common.UIAbilityContext): void { this.context = context; }
  status(): string { return this.lastError ? `Ошибка: ${this.lastError}` : (this.running ? (this.writer ? 'Запись звука' : 'Мониторинг включён') : 'Остановлено'); }
  clipsCount(): number { return this.fileCount; }
  isRunning(): boolean { return this.running; }
  clips(): string[] {
    if (!this.context) return [];
    const filenames: string[] = fs.listFileSync(this.context.filesDir);
    return filenames.filter((f: string) => f.startsWith('capture_') && f.endsWith('.wav')).sort().reverse();
  }

  private enqueue(buffer: ArrayBuffer): void {
    this.writeQueue.push(buffer.slice(0));
    if (!this.draining) { this.draining = true; setTimeout(() => this.drain(), 0); }
  }
  private drain(): void {
    try {
      while (this.writeQueue.length > 0) {
        const bytes = this.writeQueue.shift();
        if (bytes && this.writer) this.writer.append(bytes);
      }
    } catch (e) { this.lastError = String(e); }
    finally { this.draining = false; }
  }
  private openClip(): void {
    if (!this.context) return;
    this.writer = new WavWriter(`${this.context.filesDir}/capture_${Date.now()}.wav`);
    this.fileCount++;
    for (const b of this.prior) this.enqueue(b);
  }
  private closeClip(): void {
    this.drain();
    this.writer?.close();
    this.writer = undefined;
  }
  private onData = (data: ArrayBuffer): void => {
    if (!this.running) return;
    const result = this.gate.feed(data);
    if (result.opened && !this.writer) this.openClip();
    if (this.writer) this.enqueue(data);
    if (result.closed || (this.writer && this.writer.dataBytes() + this.writeQueue.length * data.byteLength >= this.maxClipBytes)) this.closeClip();
    const copy = data.slice(0);
    this.prior.push(copy);
    this.priorBytes += copy.byteLength;
    while (this.priorBytes > this.preRollBytes && this.prior.length > 0) {
      const removed = this.prior.shift();
      if (removed) this.priorBytes -= removed.byteLength;
    }
  }
  async start(): Promise<void> {
    if (this.running) return;
    if (!this.context) throw new Error('No ability context');
    this.lastError = '';
    this.gate.reset();
    this.prior = []; this.priorBytes = 0;
    const opts: audio.AudioCapturerOptions = {
      streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
                    sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 }
    };
    this.capturer = await audio.createAudioCapturer(opts);
    this.capturer.on('readData', this.onData);
    await this.capturer.start();
    this.running = true;
    try {
      const agent = await wantAgent.getWantAgent({ wants: [{ bundleName: 'com.example.watch5voicecapture', abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY, requestCode: 0, wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
      await backgroundTaskManager.startBackgroundRunning(this.context, backgroundTaskManager.BackgroundMode.AUDIO_RECORDING, agent);
      this.backgroundActive = true;
    } catch (e) {
      await this.stop();
      throw new Error('Background recording unavailable: ' + String(e));
    }
  }
  async stop(): Promise<void> {
    this.running = false;
    try { await this.capturer?.stop(); } catch (_) {}
    try { this.capturer?.off('readData', this.onData); await this.capturer?.release(); } catch (_) {}
    this.capturer = undefined;
    this.closeClip();
    if (this.backgroundActive && this.context) {
      try { await backgroundTaskManager.stopBackgroundRunning(this.context); } catch (_) {}
      this.backgroundActive = false;
    }
  }
  shutdown(): void { void this.stop(); }
}
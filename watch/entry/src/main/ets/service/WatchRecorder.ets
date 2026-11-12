import { audio } from '@kit.AudioKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { fileIo as fs, storageStatistics } from '@kit.CoreFileKit';
import { vibrator } from '@kit.SensorServiceKit';
import { preferences } from '@kit.ArkData';
import { CaptureEngine, CaptureMode, CaptureSink, Sensitivity } from './CaptureEngine';
import { WavWriter } from './WavWriter';
import { SecureConfig, ServerConfig } from './SecureConfig';
import { PersonalSetup } from './PersonalSetup';
import { Uploader } from './Uploader';
import { CompanionLink } from './CompanionLink';
import { LivePlayer } from './LivePlayer';

export class WatchRecorder implements CaptureSink {
  private static instance: WatchRecorder = new WatchRecorder();
  static getInstance(): WatchRecorder { return WatchRecorder.instance; }
  private context?: common.UIAbilityContext;
  private capturer?: audio.AudioCapturer;
  private engine: CaptureEngine = new CaptureEngine(this);
  private writer?: WavWriter;
  private starting: boolean = false;
  private stopping?: Promise<void>;
  private running: boolean = false;
  private lastError: string = '';
  private backgroundActive: boolean = false;
  private backgroundQueue: Promise<void> = Promise.resolve();
  private nextSampleMs: number = 0;
  private lastName: number = 0;
  private freeBytes: number = 0;
  private freeTimer: number = -1;
  private initialized?: Promise<void>;
  private pref?: preferences.Preferences;
  private resumeWanted: boolean = false;
  readonly companion: CompanionLink = new CompanionLink();
  private live: LivePlayer = new LivePlayer();
  private remoteRequested: boolean = false;
  private listenRequested: boolean = false;
  private wantedRunning: boolean = false;
  private switching: boolean = false;
  private companionTimer: number = -1;
  phoneFingerprint: string = '';
  phoneBundle: string = 'ru.technadzor.app';
  readonly uploader: Uploader = new Uploader();
  endpoint: string = 'https://voice.metalcarcase.ru/v1/recordings';
  sensitivity: Sensitivity = 'normal';
  mode: CaptureMode = 'auto';
  configured: boolean = false;

  setContext(context: common.UIAbilityContext): void {
    if (this.context) return;
    this.context = context;
    this.live.onEnded = (): void => { if (this.listenRequested) void this.setListening(false).catch(() => {}); };
    this.uploader.onBusy = async (_busy: boolean): Promise<void> => { await this.updateBackground(); };
    this.uploader.relayAvailable = (): boolean => this.companion.linked() && !this.listenRequested;
    this.uploader.relay = async (path: string, name: string, size: number, hash: string, progress: (value: string) => void) => {
      return this.companion.relayFile(path, name, size, hash, progress);
    };
    this.uploader.initialize(context);
    this.initialized = this.initialize();
  }
  private async initialize(): Promise<void> {
    if (!this.context) return;
    try {
      this.pref = await preferences.getPreferences(this.context, { name: 'capture-v2' });
      try { await PersonalSetup.apply(this.context, this.pref); }
      catch (_) { this.lastError = 'Личные настройки не применены · проверь настройки сервера'; }
      this.resumeWanted = await this.pref.get('resumeWanted', false) as boolean;
      this.sensitivity = await this.pref.get('sensitivity', 'normal') as Sensitivity;
      this.mode = await this.pref.get('mode', 'auto') as CaptureMode;
      this.phoneFingerprint = await this.pref.get('phoneFingerprint', '') as string;
      this.phoneBundle = await this.pref.get('phoneBundle', 'ru.technadzor.app') as string;
      this.companion.onAudio = (pcm: ArrayBuffer): void => { if (this.listenRequested) this.live.feed(pcm); };
      this.companion.initialize(this.context, this.phoneFingerprint, this.phoneBundle);
      this.companionTimer = setInterval(() => { void this.coordinateSources(); }, 1000);
      this.recover(); await this.refreshFree();
      const config = await SecureConfig.load();
      if (config) { this.endpoint = config.endpoint; this.configured = true; this.uploader.configure(config); }
    } catch (_) { this.lastError = 'Проверь настройки и сохранённые записи'; }
  }
  ready(): Promise<void> { return this.initialized || Promise.resolve(); }
  status(): string {
    if (this.companion.stopPending()) return 'СТОП на телефоне ещё не подтверждён';
    if (this.remoteRequested) return this.companion.recording() ? 'Запись · микрофон наушников' : 'Запись на телефоне не подтверждена · проверь связь';
    if (this.listenRequested && this.companion.ready()) return 'Прямой звук · наушники';
    if (this.lastError) return this.lastError;
    if (this.starting) return 'Запуск…';
    if (this.running) return this.engine.isWriting() ? 'Запись · микрофон часов' : 'Ожидание речи · микрофон часов';
    return this.resumeWanted ? 'Запись прервалась · нажми СТАРТ для продолжения' : 'Остановлено';
  }
  isRecording(): boolean { return this.running || this.starting || this.remoteRequested; }
  isRunning(): boolean { return this.isRecording() || this.listenRequested || this.companion.stopPending(); }
  recordedMs(): number { return this.remoteRequested ? (this.companion.status?.elapsed_ms || 0) : this.engine.recordedMs(); }
  freeMiB(): number { return Math.max(0, Math.floor(this.freeBytes / 1048576)); }
  clips(): string[] { return this.uploader.files(); }
  clipsCount(): number { return this.clips().length; }
  async configure(key: string): Promise<void> {
    const config: ServerConfig = { endpoint: this.endpoint, key: key.trim() };
    await SecureConfig.save(config); this.uploader.configure(config); this.configured = true;
  }
  private pulse(critical: boolean = false): void {
    vibrator.startVibration({ type: 'time', duration: critical ? 300 : 70 }, { usage: 'notification' }).catch(() => {});
  }
  private async refreshFree(): Promise<void> {
    try { this.freeBytes = await storageStatistics.getFreeSize(); }
    catch (_) { this.freeBytes = 0; }
  }
  begin(startMs: number): void {
    if (!this.context) throw new Error('No context');
    this.lastName = Math.max(Math.floor(startMs), Date.now(), this.lastName + 1);
    this.writer = new WavWriter(`${this.context.filesDir}/capture_${this.lastName}.wav`, startMs);
  }
  append(pcm: ArrayBuffer, startMs: number, source: string): void {
    if (this.freeBytes - pcm.byteLength < 8 * 1048576) throw new Error('Недостаточно памяти · записи сохранены');
    this.writer?.append(pcm, startMs, source); this.freeBytes -= pcm.byteLength;
  }
  finish(): void {
    this.writer?.close(); this.writer = undefined; this.uploader.kick();
  }
  private recover(): void {
    if (!this.context) return;
    for (const name of fs.listFileSync(this.context.filesDir)) {
      if (!/^capture_[0-9]{10,16}\.wav\.part$/.test(name)) continue;
      const path = `${this.context.filesDir}/${name.slice(0, -5)}`;
      let recovered: WavWriter | undefined;
      try { recovered = new WavWriter(path, Number(name.slice(8, -9)), true); recovered.close(); }
      catch (_) { recovered?.abandonHandle(); this.lastError = 'Есть незавершённый файл · сохранён для восстановления'; }
    }
  }
  private onData = (data: ArrayBuffer): void => {
    if (!this.running) return;
    const observedStart = Date.now() - data.byteLength / 32;
    if (this.nextSampleMs === 0 || Math.abs(observedStart - this.nextSampleMs) > 2000) this.nextSampleMs = observedStart;
    try { this.engine.feed(data, this.nextSampleMs, 'watch'); this.nextSampleMs += data.byteLength / 32; }
    catch (error) {
      this.lastError = String(error); this.pulse(true); void this.stop(false);
    }
  };
  private onInterrupt = (event: audio.InterruptEvent): void => {
    if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP || event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
      this.lastError = 'Микрофон прерван системой · нажми СТАРТ'; this.pulse(true); void this.stop(false);
    }
  };
  private updateBackground(): Promise<void> {
    this.backgroundQueue = this.backgroundQueue.catch(() => {}).then(async (): Promise<void> => {
      if (!this.context) return;
      const modes: string[] = [];
      if (this.running) modes.push('audioRecording');
      if (this.live.active) modes.push('audioPlayback');
      if (this.uploader.busy) modes.push('dataTransfer');
      if (modes.length === 0) {
        if (this.backgroundActive) await backgroundTaskManager.stopBackgroundRunning(this.context);
        this.backgroundActive = false; return;
      }
      if (this.backgroundActive) { await backgroundTaskManager.updateBackgroundRunning(this.context, modes); return; }
      const agent = await wantAgent.getWantAgent({ wants: [{ bundleName: 'com.example.watch5voicecapture', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY, requestCode: 0, actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
      await backgroundTaskManager.startBackgroundRunning(this.context, modes, agent); this.backgroundActive = true;
    });
    return this.backgroundQueue;
  }
  async configureCompanion(): Promise<void> {
    await this.pref?.put('phoneFingerprint', this.phoneFingerprint.trim());
    await this.pref?.put('phoneBundle', this.phoneBundle.trim()); await this.pref?.flush();
    await this.companion.close();
    if (this.context) this.companion.initialize(this.context, this.phoneFingerprint.trim(), this.phoneBundle.trim());
  }
  listening(): boolean { return this.listenRequested && this.live.active; }
  async setListening(enabled: boolean): Promise<void> {
    if (!this.context) return;
    if (enabled && !this.companion.ready()) throw new Error('Открой помощник в Прораб+');
    this.listenRequested = enabled;
    try {
      if (enabled) await this.live.start(this.context); else await this.live.stop();
      await this.companion.command(this.remoteRequested ? this.mode : 'listen', this.sensitivity, enabled);
      await this.updateBackground();
    } catch (error) { this.listenRequested = false; await this.live.stop(); throw error as Error; }
  }
  private async coordinateSources(): Promise<void> {
    if (this.switching || this.starting || this.stopping) return;
    this.switching = true;
    try {
      if (this.remoteRequested && this.companion.stopped()) {
        this.remoteRequested = false; this.wantedRunning = false; this.listenRequested = false;
        this.resumeWanted = false; await this.live.stop(); await this.updateBackground();
        await this.pref?.put('resumeWanted', false); await this.pref?.flush();
      }
      if (!this.wantedRunning && !this.remoteRequested && this.companion.recording() && !this.companion.stopPending()) {
        this.remoteRequested = true; this.wantedRunning = true; this.resumeWanted = true;
      }
      if (this.listenRequested && !this.companion.ready()) {
        this.listenRequested = false; await this.live.stop(); await this.updateBackground();
      }
      if (this.wantedRunning && this.companion.ready() && !this.remoteRequested) {
        await this.companion.command(this.mode, this.sensitivity, this.listenRequested);
        await this.performStop(false); this.remoteRequested = true;
      } else if (this.wantedRunning && this.remoteRequested && this.companion.sourceLost()) {
        this.remoteRequested = false;
        try { await this.companion.command('listen', this.sensitivity, false); } catch (_) {}
        await this.startLocal(); this.pulse(true);
      }
    } catch (_) { /* Keep the current source until a replacement is confirmed. */ }
    finally { this.switching = false; }
  }
  async start(): Promise<void> {
    await this.ready();
    if (this.isRecording() || this.companion.stopPending()) return;
    this.lastError = ''; this.wantedRunning = true;
    if (this.companion.ready()) {
      try {
        await this.companion.command(this.mode, this.sensitivity, this.listenRequested);
        this.remoteRequested = true; this.resumeWanted = true;
        await this.pref?.put('resumeWanted', true); await this.pref?.flush();
        this.pulse(); return;
      } catch (_) { this.remoteRequested = true; throw new Error('Телефон не подтвердил запись · СТОП отменит запрос'); }
    }
    try { await this.startLocal(); } catch (error) { this.wantedRunning = false; throw error as Error; }
  }
  private async startLocal(): Promise<void> {
    if (this.running || this.starting) return;
    this.starting = true;
    try {
      await this.ready(); if (this.stopping) await this.stopping;
      if (!this.context) throw new Error('Нет контекста приложения');
      await this.refreshFree(); if (this.freeBytes < 9 * 1048576) throw new Error('Недостаточно памяти');
      this.lastError = ''; this.recover(); this.nextSampleMs = 0;
      this.engine = new CaptureEngine(this); this.engine.mode = this.mode; this.engine.gate.sensitivity = this.sensitivity;
      this.capturer = await audio.createAudioCapturer({
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 } });
      this.capturer.on('readData', this.onData); this.capturer.on('audioInterrupt', this.onInterrupt);
      this.running = true;
      await this.capturer.start(); await this.updateBackground();
      this.resumeWanted = true;
      await this.pref?.put('resumeWanted', true); await this.pref?.put('mode', this.mode);
      await this.pref?.put('sensitivity', this.sensitivity); await this.pref?.flush();
      this.freeTimer = setInterval(() => { void this.refreshFree(); }, 5000);
      this.pulse(); this.uploader.kick();
    } catch (error) {
      await this.stop(false); this.lastError = 'Не удалось начать запись: ' + String(error); throw error as Error;
    } finally { this.starting = false; }
  }
  stop(userRequested: boolean = true): Promise<void> {
    if (this.stopping) return this.stopping;
    this.wantedRunning = false;
    this.stopping = this.stopAll(userRequested).finally(() => { this.stopping = undefined; });
    return this.stopping;
  }
  private async stopAll(userRequested: boolean): Promise<void> {
    const remote = this.remoteRequested || this.listenRequested || this.companion.recording() || this.companion.stopPending();
    this.remoteRequested = false; this.listenRequested = false;
    await this.live.stop();
    if (userRequested && remote) {
      try { await this.companion.command('listen', this.sensitivity, false, true); }
      catch (_) { this.lastError = 'СТОП на телефоне не подтверждён · проверь Прораб+'; }
    }
    await this.performStop(userRequested);
  }
  private async performStop(userRequested: boolean): Promise<void> {
    this.running = false;
    if (this.freeTimer !== -1) clearInterval(this.freeTimer); this.freeTimer = -1;
    try { await this.capturer?.stop(); } catch (_) {}
    try { this.capturer?.off('readData', this.onData); this.capturer?.off('audioInterrupt'); await this.capturer?.release(); } catch (_) {}
    this.capturer = undefined;
    try { this.engine.stop(); }
    catch (_) { this.writer?.abandonHandle(); this.writer = undefined; this.lastError = 'Файл сохранён для восстановления'; }
    if (userRequested) {
      this.resumeWanted = false; await this.pref?.put('resumeWanted', false); await this.pref?.flush(); this.pulse();
    }
    try { await this.updateBackground(); } catch (_) {}
    this.uploader.kick();
  }
  shutdown(): void {
    this.uploader.close(); if (this.companionTimer !== -1) clearInterval(this.companionTimer);
    void this.companion.close(); void this.stop(false);
  }
}

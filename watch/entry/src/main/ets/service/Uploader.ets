import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileHash } from '@kit.CoreFileKit';
import { http, connection } from '@kit.NetworkKit';
import { canDeleteRecording, UploadReceipt } from './UploadReceipt';
import { DeferredUpload } from './DeferredUpload';
import { ServerConfig } from './SecureConfig';

/** Durable outbox: the finalized WAV files themselves are the queue. */
export class Uploader {
  status: string = 'Настрой подключение к серверу';
  pending: number = 0;
  sent: number = 0;
  lastSuccess: string = '';
  busy: boolean = false;
  onBusy: (busy: boolean) => Promise<void> = async (_busy: boolean): Promise<void> => {};
  private context?: common.Context;
  private config?: ServerConfig;
  private timer: number = -1;
  private failures: number = 0;
  private net?: connection.NetConnection;
  private closed: boolean = false;
  private request?: http.HttpRequest;
  relayAvailable: () => boolean = (): boolean => false;
  relay?: (path: string, name: string, size: number, hash: string, progress: (value: string) => void) => Promise<UploadReceipt>;

  files(): string[] {
    if (!this.context) return [];
    return fs.listFileSync(this.context.filesDir).filter((name: string) => /^capture_[0-9]{10,16}\.wav$/.test(name)).sort();
  }
  initialize(context: common.Context): void {
    this.context = context; this.closed = false; this.pending = this.files().length;
    this.net = connection.createNetConnection();
    this.net.on('netAvailable', () => { this.kick(); });
    this.net.register().catch(() => {});
  }
  configure(config: ServerConfig): void { this.config = config; this.failures = 0; this.kick(); }
  kick(): void {
    if (this.closed || this.busy) return;
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = -1;
    void this.run();
  }
  private async run(): Promise<void> {
    if (this.busy || !this.context || this.closed) return;
    this.pending = this.files().length;
    if (this.pending > 0) void DeferredUpload.ensure();
    if (!this.config) return;
    if (this.pending === 0) { this.status = 'Все записи на Диске'; return; }
    if (!connection.hasDefaultNetSync() && !this.relayAvailable()) { this.retry('Нет сети · записи сохранены'); return; }
    this.busy = true;
    try {
      await this.onBusy(true);
      const files = this.files();
      for (const name of files) {
        if (this.closed) break;
        try { await this.uploadOne(name, this.config); }
        catch (error) {
          if (!this.relayAvailable() || !this.relay) throw error;
          const path = `${this.context.filesDir}/${name}`;
          const size = fs.statSync(path).size; const hash = await fileHash.hash(path, 'sha256');
          const receipt = await this.relay(path, name, size, hash, (message: string): void => { this.status = message; });
          if (!canDeleteRecording(receipt, name, size, hash)) throw new Error('Unverified relay receipt');
          fs.unlinkSync(path);
        }
        this.sent++; this.lastSuccess = new Date().toLocaleTimeString();
        this.pending = this.files().length; this.failures = 0;
      }
      this.status = 'Все записи на Диске';
    } catch (_) {
      this.failures++;
      this.status = 'Загрузка не подтверждена · файл сохранён';
    } finally {
      this.busy = false;
      try { await this.onBusy(false); } catch (_) {}
      this.pending = this.files().length;
      if (this.pending > 0 && !this.closed) this.retry(this.status);
    }
  }
  private retry(message: string): void {
    this.status = message;
    this.timer = setTimeout(() => { this.timer = -1; void this.run(); },
      Math.min(300000, 15000 * Math.pow(2, Math.min(this.failures, 5))));
  }
  private async uploadOne(name: string, config: ServerConfig): Promise<void> {
    if (!this.context) return;
    if (!connection.hasDefaultNetSync()) throw new Error('No direct network');
    const path = `${this.context.filesDir}/${name}`;
    const size = fs.statSync(path).size;
    if (size > 24 * 1024 * 1024 || size < 44) throw new Error('Invalid recording size');
    const sha256 = await fileHash.hash(path, 'sha256');
    const bytes = new ArrayBuffer(size);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      let offset = 0;
      while (offset < size) {
        const piece = new ArrayBuffer(Math.min(65536, size - offset));
        const n = fs.readSync(file.fd, piece, { offset: offset });
        if (n <= 0) throw new Error('Incomplete recording');
        new Uint8Array(bytes).set(new Uint8Array(piece, 0, n), offset); offset += n;
      }
    } finally { fs.closeSync(file); }
    const req = http.createHttp(); this.request = req;
    req.on('dataSendProgress', (progress: http.DataSendProgressInfo) => {
      const percent = progress.totalSize > 0 ? Math.min(100, Math.floor(progress.sendSize * 100 / progress.totalSize)) : 0;
      this.status = percent < 100 ? `На сервер: ${percent}% · очередь ${this.pending}` : 'Сохранение и проверка на Диске…';
    });
    try {
      const result = await req.request(`${config.endpoint}?filename=${encodeURIComponent(name)}`, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'audio/wav', 'X-Device-Key': config.key },
        extraData: bytes, connectTimeout: 20000, readTimeout: 180000,
        usingCache: false, maxLimit: 65536
      });
      if (result.responseCode !== 201 || typeof result.result !== 'string') throw new Error('Upload failed');
      const receipt = JSON.parse(result.result) as UploadReceipt;
      if (!canDeleteRecording(receipt, name, size, sha256)) throw new Error('Cloud receipt not verified');
      fs.unlinkSync(path);
    } finally { req.off('dataSendProgress'); req.destroy(); this.request = undefined; }
  }
  close(): void {
    this.closed = true;
    this.request?.destroy(); this.request = undefined;
    if (this.timer !== -1) clearTimeout(this.timer);
    this.net?.unregister().catch(() => {});
  }
}

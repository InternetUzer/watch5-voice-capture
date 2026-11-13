import { common } from '@kit.AbilityKit';
import { fileIo as fs, hash as fileHash } from '@kit.CoreFileKit';
import { http, connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
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
  lastAttempt: string = '';
  backgroundNotice: string = '';
  private stage: string = '';
  private failureDetail: string = '';
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
    // NetConnection registration uses a callback, not a Promise. Upload retries
    // still work if the optional network-change listener cannot be registered.
    try { this.net.register((_error: BusinessError): void => {}); } catch (_) {}
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
    this.lastAttempt = new Date().toLocaleTimeString();
    this.failureDetail = ''; this.backgroundNotice = '';
    this.stage = 'Подготовка передачи';
    try {
      // A denied background task must not prevent a foreground HTTP attempt.
      try { await this.onBusy(true); }
      catch (_) { this.backgroundNotice = 'Фоновая передача недоступна · оставь приложение открытым'; }
      const files = this.files();
      for (const name of files) {
        if (this.closed) break;
        try { await this.uploadOne(name, this.config); }
        catch (error) {
          if (!this.relayAvailable() || !this.relay) throw error as Error;
          const path = `${this.context.filesDir}/${name}`;
          const size = fs.statSync(path).size;
          const hash: string = (await fileHash.hash(path, 'sha256')).toLowerCase();
          this.stage = 'Передача через телефон'; this.failureDetail = '';
          const receipt = await this.relay(path, name, size, hash, (message: string): void => { this.status = message; });
          if (!canDeleteRecording(receipt, name, size, hash)) throw this.failure('Телефон: квитанция Диска не подтверждена');
          fs.unlinkSync(path);
        }
        this.sent++; this.lastSuccess = new Date().toLocaleTimeString();
        this.pending = this.files().length; this.failures = 0;
      }
      this.status = 'Все записи на Диске';
    } catch (error) {
      this.failures++;
      const code = (error as BusinessError).code;
      const suffix = typeof code === 'number' && Number.isFinite(code) ? ` · код ${code}` : '';
      this.status = (this.failureDetail || this.stage + suffix) + ' · файл сохранён';
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
  private failure(message: string): Error {
    this.failureDetail = message;
    return new Error(message);
  }
  private httpFailure(code: number): string {
    if (code === 401 || code === 403) return `HTTP ${code}: проверь ключ и доступ к API`;
    if (code === 404) return 'HTTP 404: проверь адрес API';
    if (code === 413) return 'HTTP 413: сервер отклонил размер файла';
    if (code === 422) return 'HTTP 422: сервер отклонил формат WAV';
    if (code === 502) return 'HTTP 502: сервер не подтвердил загрузку на Диск';
    return `HTTP ${code}: загрузка не принята`;
  }
  private async uploadOne(name: string, config: ServerConfig): Promise<void> {
    if (!this.context) return;
    if (!connection.hasDefaultNetSync()) throw this.failure('Нет прямого подключения к интернету');
    this.stage = 'Чтение файла на часах';
    const path = `${this.context.filesDir}/${name}`;
    const size = fs.statSync(path).size;
    if (size > 24 * 1024 * 1024 || size < 44) throw this.failure('Некорректный размер файла на часах');
    // CoreFileKit returns uppercase hex; the server/phone protocol uses lowercase.
    const sha256: string = (await fileHash.hash(path, 'sha256')).toLowerCase();
    const bytes = new ArrayBuffer(size);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      let offset = 0;
      while (offset < size) {
        const piece = new ArrayBuffer(Math.min(65536, size - offset));
        const n = fs.readSync(file.fd, piece, { offset: offset });
        if (n <= 0) throw this.failure('Не удалось прочитать файл целиком');
        new Uint8Array(bytes).set(new Uint8Array(piece, 0, n), offset); offset += n;
      }
    } finally { fs.closeSync(file); }
    const req = http.createHttp(); this.request = req;
    req.on('dataSendProgress', (progress: http.DataSendProgressInfo) => {
      const percent = progress.totalSize > 0 ? Math.min(100, Math.floor(progress.sendSize * 100 / progress.totalSize)) : 0;
      this.status = percent < 100 ? `На сервер: ${percent}% · очередь ${this.pending}` : 'Сохранение и проверка на Диске…';
    });
    try {
      this.stage = 'Сеть / DNS / TLS: запрос не завершён';
      const result = await req.request(`${config.endpoint}?filename=${encodeURIComponent(name)}`, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'audio/wav', 'X-Device-Key': config.key },
        extraData: bytes, connectTimeout: 20000, readTimeout: 180000,
        usingCache: false, maxLimit: 65536
      });
      if (result.responseCode !== 201) throw this.failure(this.httpFailure(result.responseCode));
      if (typeof result.result !== 'string') throw this.failure('HTTP 201: ответ сервера не является JSON-строкой');
      this.stage = 'HTTP 201: разбор квитанции';
      let receipt: UploadReceipt;
      try { receipt = JSON.parse(result.result as string) as UploadReceipt; }
      catch (_) { throw this.failure('HTTP 201: некорректный JSON'); }
      if (!receipt || !canDeleteRecording(receipt, name, size, sha256)) throw this.failure('HTTP 201: квитанция, размер или SHA-256 не совпали');
      this.stage = 'Удаление подтверждённой локальной копии';
      fs.unlinkSync(path);
    } finally { req.off('dataSendProgress'); req.destroy(); this.request = undefined; }
  }
  close(): void {
    this.closed = true;
    this.request?.destroy(); this.request = undefined;
    if (this.timer !== -1) clearTimeout(this.timer);
    try { this.net?.unregister((_error: BusinessError): void => {}); } catch (_) {}
    this.net = undefined;
  }
}

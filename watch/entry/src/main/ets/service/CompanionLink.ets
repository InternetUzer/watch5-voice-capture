import { common } from '@kit.AbilityKit';
import { wearEngine } from '@kit.WearEngine';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { UploadReceipt } from './UploadReceipt';
import { decodeLiveFrame } from './LiveProtocol';

export interface CompanionStatus {
  type: string; session: number; id: number; source_available: boolean; stopped: boolean;
  mode: string; listening: boolean; elapsed_ms: number; queue: number; upload: string; source: string;
}
export interface CompanionCommand {
  type: string; session: number; id: number; mode: string; sensitivity: string; listening: boolean; stop: boolean;
}
interface RelayQuery { type: string; filename: string; bytes: number; sha256: string; }
interface RelayReply { type: string; filename: string; bytes: number; sha256: string; accepted: boolean; need_file: boolean; receipt?: UploadReceipt; }
export class CompanionLink {
  status: CompanionStatus | undefined;
  message: string = 'Прораб+ не подключён';
  onAudio: (pcm: ArrayBuffer) => void = (_pcm: ArrayBuffer): void => {};
  private context?: common.UIAbilityContext;
  private client?: wearEngine.P2pClient;
  private peer: string = '';
  private app: wearEngine.P2pAppParam = { remoteApp: { bundleName: 'ru.technadzor.app', fingerprint: '' } };
  private seen: number = 0;
  private lastSequence: number = -1;
  private commandId: number = 0;
  private timer: number = -1;
  private pending?: CompanionCommand;
  private relayReply?: RelayReply;
  private connecting: boolean = false;
  private closed: boolean = false;

  ready(): boolean { return !!this.status && Date.now() - this.seen < 4000 && this.status.source_available && !this.status.stopped; }
  linked(): boolean { return !!this.status && Date.now() - this.seen < 4000 && !this.status.stopped; }
  stopped(): boolean { return !!this.status && Date.now() - this.seen < 4000 && this.status.stopped; }
  sourceLost(): boolean { return this.linked() && !this.status?.source_available; }
  recording(): boolean { return this.ready() && this.status?.mode !== 'listen'; }
  stopPending(): boolean { return this.pending?.stop === true; }
  initialize(context: common.UIAbilityContext, fingerprint: string, bundle: string): void {
    this.context = context; this.closed = false;
    this.status = undefined; this.seen = 0; this.peer = ''; this.pending = undefined;
    this.app = { remoteApp: { bundleName: bundle, fingerprint: fingerprint } };
    if (!fingerprint || !canIUse('SystemCapability.Health.WearEngine')) { this.message = 'Настрой связь с Прораб+'; return; }
    this.client = wearEngine.getP2pClient(context);
    this.timer = setInterval(() => { void this.connect(); }, 3000);
    void this.connect();
  }
  private async connect(): Promise<void> {
    if (!this.context || !this.client || this.connecting || this.closed) return;
    this.connecting = true;
    try {
      const devices = await wearEngine.getDeviceClient(this.context).getConnectedDevices();
      if (devices.length !== 1) { this.message = 'Телефон не подключён'; return; }
      if (this.peer !== devices[0].randomId || Date.now() - this.seen > 6000) {
        if (this.peer) { try { await this.client.unregisterMessageReceiver(this.peer, this.app, this.receive); } catch (_) {} }
        this.peer = devices[0].randomId;
        await this.client.registerMessageReceiver(this.peer, this.app, this.receive);
        this.message = 'Открой помощник часов в Прораб+';
      }
      if (this.pending && this.peer) await this.transmit(this.pending);
    } catch (_) { this.message = 'Wear Engine: проверь регистрацию и подпись'; }
    finally { this.connecting = false; }
  }
  private receive = (message: wearEngine.P2pMessage): void => {
    if (this.closed) return;
    const frame = decodeLiveFrame(message.content);
    if (frame) {
      if (this.status && frame.session === this.status.session && frame.sequence > this.lastSequence && this.ready()) {
        this.lastSequence = frame.sequence; this.onAudio(frame.pcm);
      }
      return;
    }
    if (message.content.byteLength > 4096) return;
    try {
      const text = util.TextDecoder.create('utf-8').decodeWithStream(message.content);
      const relay = JSON.parse(text) as RelayReply;
      if (relay.type === 'relay') { this.relayReply = relay; return; }
      const state = JSON.parse(text) as CompanionStatus;
      if (state.type !== 'status' || !Number.isInteger(state.session) || !Number.isFinite(state.id) ||
        !Number.isFinite(state.elapsed_ms) || state.elapsed_ms < 0 || state.elapsed_ms > 600000 ||
        !['auto', 'continuous', 'listen'].includes(state.mode) ||
        typeof state.source_available !== 'boolean' || typeof state.stopped !== 'boolean' ||
        typeof state.listening !== 'boolean' || typeof state.source !== 'string' || typeof state.upload !== 'string' ||
        !Number.isInteger(state.queue) || state.queue < 0) return;
      if (this.status?.session !== state.session) { this.lastSequence = -1; this.pending = undefined; }
      this.status = state; this.seen = Date.now(); this.commandId = Math.max(this.commandId, state.id);
      if (this.pending && state.id >= this.pending.id) this.pending = undefined;
      this.message = state.stopped ? 'Помощник остановлен' : state.source;
    } catch (_) {}
  };
  async command(mode: string, sensitivity: string, listening: boolean, stop: boolean = false): Promise<void> {
    if (!this.status || !this.peer) throw new Error('Нет связи с Прораб+');
    this.commandId = Math.max(this.commandId + 1, Date.now());
    this.pending = { type: 'control', session: this.status.session, id: this.commandId,
      mode: mode, sensitivity: sensitivity, listening: listening, stop: stop };
    this.message = stop ? 'Остановка на телефоне · ждём подтверждение' : 'Команда отправляется…';
    const command = this.pending;
    await this.transmit(command);
    for (let i = 0; i < 30; i++) {
      if (this.status?.session === command.session && this.status.id >= command.id) return;
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 100); });
    }
    throw new Error('Нет подтверждения команды');
  }
  private async transmit(command: CompanionCommand): Promise<void> {
    if (!this.client) throw new Error('Нет канала связи');
    const result = await this.client.sendMessage(this.peer, this.app, { content: new util.TextEncoder().encodeInto(JSON.stringify(command)) });
    if (result.code !== wearEngine.P2pResultCode.COMMUNICATION_SUCCESS) throw new Error('Команда не доставлена');
  }
  // The receive callback can update this field while relayFile is awaiting.
  // Read through a method so control-flow analysis does not pin it to undefined.
  private currentRelayReply(): RelayReply | undefined { return this.relayReply; }

  async relayFile(path: string, name: string, size: number, hash: string, progress: (value: string) => void): Promise<UploadReceipt> {
    if (!this.client || !this.linked()) throw new Error('Phone unavailable');
    const request: RelayQuery = { type: 'relay_query', filename: name, bytes: size, sha256: hash };
    this.relayReply = undefined;
    await this.client.sendMessage(this.peer, this.app, { content: new util.TextEncoder().encodeInto(JSON.stringify(request)) });
    let reply: RelayReply | undefined;
    for (let i = 0; i < 50; i++) {
      const candidate = this.currentRelayReply();
      if (candidate && candidate.filename === name && candidate.sha256 === hash && candidate.bytes === size) { reply = candidate; break; }
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 100); });
    }
    if (!reply) throw new Error('Phone did not acknowledge file query');
    if (reply.receipt) return reply.receipt;
    if (reply.accepted) { progress('Копия на телефоне · ожидаем подтверждение Диска'); throw new Error('Awaiting cloud receipt'); }
    if (!reply.need_file) throw new Error('Phone rejected file');
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const client = this.client;
    try {
      await new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
        const timeout = setTimeout(() => { reject(new Error('File transfer timeout')); }, 300000);
        client.transferFile(this.peer, this.app, { file: file }, (error: BusinessError, result: wearEngine.P2pResult): void => {
          if (error) { clearTimeout(timeout); reject(new Error('File transfer failed')); return; }
          if (result.progress !== undefined) progress(`На телефон: ${result.progress}%`);
          if (result.code === wearEngine.P2pResultCode.COMMUNICATION_SUCCESS || result.progress === 100) {
            clearTimeout(timeout); resolve();
          } else if (result.code !== undefined) { clearTimeout(timeout); reject(new Error('File transfer rejected')); }
        });
      });
    } finally { fs.closeSync(file); }
    progress('Передано на телефон · оригинал остаётся до проверки Диска');
    throw new Error('Awaiting cloud receipt');
  }
  async close(): Promise<void> {
    this.closed = true;
    if (this.timer !== -1) clearInterval(this.timer);
    if (this.peer && this.client) {
      try { await this.client.unregisterMessageReceiver(this.peer, this.app, this.receive); } catch (_) {}
    }
  }
}

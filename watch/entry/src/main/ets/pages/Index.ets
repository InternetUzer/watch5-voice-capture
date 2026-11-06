import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { WatchRecorder } from '../service/WatchRecorder';

@Entry
@Component
struct Index {
  @State state: string = 'Загрузка…';
  @State running: boolean = false;
  @State recording: boolean = false;
  @State elapsed: number = 0;
  @State pending: number = 0;
  @State free: number = 0;
  @State transfer: string = '';
  @State success: string = '';
  @State auto: boolean = true;
  @State sensitivity: string = 'Обычная';
  @State settings: boolean = false;
  @State configured: boolean = false;
  @State endpoint: string = 'https://voice.metalcarcase.ru/v1/recordings';
  @State token: string = '';
  @State message: string = '';
  @State listening: boolean = false;
  @State phoneFingerprint: string = '';
  @State phoneBundle: string = 'ru.technadzor.app';
  @State phoneStatus: string = '';
  private recorder: WatchRecorder = WatchRecorder.getInstance();
  private timer: number = -1;

  aboutToAppear(): void {
    this.recorder.setContext(getContext(this) as common.UIAbilityContext);
    this.recorder.ready().then(() => {
      this.auto = this.recorder.mode === 'auto'; this.endpoint = this.recorder.endpoint;
      this.phoneFingerprint = this.recorder.phoneFingerprint; this.phoneBundle = this.recorder.phoneBundle;
      this.refresh();
    });
    this.timer = setInterval(() => { this.refresh(); }, 500);
  }
  aboutToDisappear(): void { if (this.timer !== -1) clearInterval(this.timer); }
  private refresh(): void {
    this.state = this.recorder.status(); this.running = this.recorder.isRunning(); this.recording = this.recorder.isRecording();
    this.elapsed = this.recorder.recordedMs(); this.pending = this.recorder.clipsCount();
    this.free = this.recorder.freeMiB(); this.transfer = this.recorder.uploader.status;
    this.listening = this.recorder.listening(); this.phoneStatus = this.recorder.companion.message;
    if (this.recorder.companion.ready()) {
      this.pending += this.recorder.companion.status?.queue || 0;
      this.transfer += '\nТелефон: ' + (this.recorder.companion.status?.upload || '');
    }
    this.success = this.recorder.uploader.lastSuccess; this.configured = this.recorder.configured;
    this.sensitivity = this.recorder.sensitivity === 'high' ? 'Высокая' : (this.recorder.sensitivity === 'low' ? 'Низкая' : 'Обычная');
  }
  private time(ms: number): string {
    const seconds = Math.max(0, Math.floor(ms / 1000));
    return `${Math.floor(seconds / 60)}:${(seconds % 60).toString().padStart(2, '0')}`;
  }
  private async begin(): Promise<void> {
    this.message = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      if (result.authResults.length === 0 || result.authResults[0] !== 0) { this.message = 'Разреши доступ к микрофону'; return; }
      await this.recorder.start();
    } catch (_) { this.message = 'Не удалось запустить запись'; }
    this.refresh();
  }
  private async save(): Promise<void> {
    try {
      this.recorder.endpoint = this.endpoint;
      await this.recorder.configure(this.token); this.token = ''; this.settings = false; this.message = '';
    } catch (_) { this.message = 'Не удалось сохранить настройки в защищённом хранилище'; }
    this.refresh();
  }
  build() {
    Scroll() {
      Column({ space: 8 }) {
        Text('VOICE CAPTURE').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#55D5C3')
        Text(this.state).fontSize(12).fontColor('#FFFFFF').textAlign(TextAlign.Center)
        Text(`${this.time(this.elapsed)} / 10:00`).fontSize(25).fontColor('#FFFFFF')
        Progress({ value: this.elapsed / 6000, total: 100, type: ProgressType.Linear }).color('#55D5C3')
        Text(`Осталось ${this.time(600000 - this.elapsed)}`).fontSize(11).fontColor('#CCD5DF')
        Row({ space: 8 }) {
          Button('СТАРТ').enabled(!this.recording && !this.recorder.companion.stopPending()).onClick(() => { void this.begin(); })
          Button('СТОП').enabled(this.running).onClick(() => { void this.recorder.stop().then(() => { this.refresh(); }); })
        }
        Button(this.listening ? 'Выключить звук' : 'Слушать наушники').fontSize(12)
          .onClick(() => {
            void this.recorder.setListening(!this.listening).then(() => { this.refresh(); })
              .catch(() => { this.message = 'Открой помощник часов в Прораб+'; });
          })
        Text(this.phoneStatus).fontSize(10).fontColor('#CCD5DF')
        Button(this.auto ? 'Режим: авто' : 'Режим: непрерывно').fontSize(12).enabled(!this.recording)
          .onClick(() => { this.auto = !this.auto; this.recorder.mode = this.auto ? 'auto' : 'continuous'; })
        Button(`Чувствительность: ${this.sensitivity}`).fontSize(11).enabled(!this.recording)
          .onClick(() => {
            this.recorder.sensitivity = this.recorder.sensitivity === 'normal' ? 'high' : (this.recorder.sensitivity === 'high' ? 'low' : 'normal');
            this.refresh();
          })
        Text(`В очереди: ${this.pending} · свободно ${this.free} МБ`).fontSize(11).fontColor('#CCD5DF')
        Text(this.transfer).fontSize(11).fontColor('#55D5C3').textAlign(TextAlign.Center)
        if (this.success) { Text(`На Диске: ${this.success}`).fontSize(10).fontColor('#CCD5DF') }
        if (this.message) { Text(this.message).fontSize(11).fontColor('#FFBBAA') }
        if (!this.configured) {
          Text('Без настройки сервера записи сохраняются на часах.').fontSize(10).fontColor('#FFDB99')
        }
        Button('Настройки сервера').fontSize(11).onClick(() => { this.settings = !this.settings; })
        if (this.settings) {
          TextInput({ placeholder: 'HTTPS API', text: this.endpoint }).fontSize(10).onChange((v: string) => { this.endpoint = v; })
          TextInput({ placeholder: 'Ключ устройства', text: this.token }).type(InputType.Password).fontSize(10)
            .onChange((v: string) => { this.token = v; })
          Button('Сохранить ключ').onClick(() => { void this.save(); })
          TextInput({ placeholder: 'Отпечаток подписи Прораб+', text: this.phoneFingerprint }).fontSize(10)
            .onChange((v: string) => { this.phoneFingerprint = v; })
          TextInput({ placeholder: 'Пакет Прораб+', text: this.phoneBundle }).fontSize(10)
            .onChange((v: string) => { this.phoneBundle = v; })
          Button('Подключить Прораб+').onClick(() => {
            this.recorder.phoneFingerprint = this.phoneFingerprint; this.recorder.phoneBundle = this.phoneBundle;
            void this.recorder.configureCompanion().catch(() => { this.message = 'Не удалось настроить связь'; });
          })
        }
      }.width('100%').padding({ top: 32, bottom: 40, left: 25, right: 25 })
    }.width('100%').height('100%').backgroundColor('#101A25')
  }
}

import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { WatchRecorder } from '../service/WatchRecorder';
import { Uploader } from '../service/Uploader';

@Entry
@Component
struct Index {
  @State state: string = 'Остановлено';
  @State count: number = 0;
  @State endpoint: string = '';
  @State token: string = '';
  @State transferStatus: string = '';
  private recorder: WatchRecorder = WatchRecorder.getInstance();
  private uploader: Uploader = new Uploader();

  private async begin(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const manager = abilityAccessCtrl.createAtManager();
      const response = await manager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      if (response.authResults.length < 1 || response.authResults[0] !== 0) {
        this.state = 'Нет разрешения на микрофон'; return;
      }
      await this.recorder.start();
      this.state = this.recorder.status();
    } catch (e) { this.state = 'Не удалось запустить: ' + String(e); }
  }
  private async finish(): Promise<void> {
    await this.recorder.stop();
    this.state = this.recorder.status(); this.count = this.recorder.clips().length;
  }
  private async upload(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const clips = this.recorder.clips();
    if (clips.length === 0) { this.transferStatus = 'Нет файлов'; return; }
    this.transferStatus = 'Отправка...';
    try {
      const sent = await this.uploader.uploadFiles(context, clips, this.endpoint, this.token);
      this.transferStatus = `Отправлено: ${sent}/${clips.length}`;
    } catch (e) { this.transferStatus = 'Ошибка отправки: ' + String(e); }
  }
  build() {
    Column({ space: 8 }) {
      Text('VOICE CAPTURE').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#55D5C3')
      Text(this.state).fontSize(11).fontColor('#FFFFFF').textAlign(TextAlign.Center)
      Button('СТАРТ').enabled(!this.recorder.isRunning()).onClick(() => { void this.begin(); })
      Button('СТОП').enabled(this.recorder.isRunning()).onClick(() => { void this.finish(); })
      Text(`Файлов: ${this.count}`).fontSize(11).fontColor('#FFFFFF')
      TextInput({ placeholder: 'https://host/v1/recordings', text: this.endpoint }).fontSize(10)
        .onChange((v: string) => { this.endpoint = v; })
      TextInput({ placeholder: 'API key', text: this.token }).fontSize(10).type(InputType.Password)
        .onChange((v: string) => { this.token = v; })
      Button('Отправить файлы').onClick(() => { void this.upload(); })
      Text(this.transferStatus).fontSize(10).fontColor('#FFFFFF')
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('#101A25').padding(10)
  }
}
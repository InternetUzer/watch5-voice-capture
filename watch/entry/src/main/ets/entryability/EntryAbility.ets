import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { WatchRecorder } from '../service/WatchRecorder';
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    WatchRecorder.getInstance().setContext(this.context);
  }
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index');
  }
  onDestroy(): void {
    WatchRecorder.getInstance().shutdown();
  }
}
import nativeVad from 'libwatchvad.so';
import { Sensitivity, VoiceDetector } from './CaptureEngine';

/** Local, offline WebRTC; no RMS gate in front that could suppress quiet speech. */
export class WebRtcDetector implements VoiceDetector {
  private instance?: nativeVad.WebRtcVad;
  private mode: number = -1;

  detect(pcm: ArrayBuffer, sensitivity: Sensitivity): boolean {
    const mode = sensitivity === 'high' ? 0 : (sensitivity === 'low' ? 2 : 1);
    if (!this.instance) this.instance = new nativeVad.WebRtcVad(mode);
    else if (this.mode !== mode) this.instance.reset(mode);
    this.mode = mode;
    return this.instance.process(pcm);
  }

  reset(): void {
    if (this.instance) this.instance.reset(this.mode);
  }

  close(): void {
    this.instance?.close(); this.instance = undefined; this.mode = -1;
  }
}

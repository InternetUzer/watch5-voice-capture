import { audio } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { common } from '@kit.AbilityKit';

/** Bounded listening queue. Archival happens on the phone, not in this lossy live buffer. */
export class LivePlayer {
  private renderer?: audio.AudioRenderer;
  private session?: avSession.AVSession;
  private queue: ArrayBuffer[] = [];
  private draining: boolean = false;
  active: boolean = false;
  private generation: number = 0;
  private starting?: Promise<void>;
  onEnded: () => void = (): void => {};
  start(context: common.UIAbilityContext): Promise<void> {
    if (this.active) return Promise.resolve();
    if (this.starting) return this.starting;
    this.starting = this.begin(context).finally(() => { this.starting = undefined; });
    return this.starting;
  }
  private async begin(context: common.UIAbilityContext): Promise<void> {
    const generation = ++this.generation;
    this.renderer = await audio.createAudioRenderer({
      streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      rendererInfo: { content: audio.ContentType.CONTENT_TYPE_SPEECH, usage: audio.StreamUsage.STREAM_USAGE_VOICE_MESSAGE, rendererFlags: 0 } });
    await this.renderer.setDefaultOutputDevice(audio.DeviceType.SPEAKER);
    this.session = await avSession.createAVSession(context, 'Наушники · Прораб+', 'audio');
    await this.session.setAVMetadata({ assetId: 'watch5-live', title: 'Прямой звук микрофона наушников' });
    this.session.on('pause', () => { void this.stop().then(() => { this.onEnded(); }); });
    this.session.on('stop', () => { void this.stop().then(() => { this.onEnded(); }); });
    await this.session.activate(); await this.renderer.start();
    await this.session.setAVPlaybackState({ state: avSession.PlaybackState.PLAYBACK_STATE_PLAY });
    if (generation !== this.generation) { await this.stop(); return; }
    this.active = true;
  }
  feed(pcm: ArrayBuffer): void {
    if (!this.active) return;
    if (this.queue.length >= 5) this.queue.shift();
    this.queue.push(pcm); if (!this.draining) void this.drain();
  }
  private async drain(): Promise<void> {
    this.draining = true;
    const renderer = this.renderer;
    try {
      while (this.active && this.queue.length > 0 && renderer) {
        const pcm = this.queue.shift(); if (!pcm) continue;
        let offset = 0;
        while (this.active && offset < pcm.byteLength) {
          const count = await renderer.write(pcm.slice(offset));
          if (count <= 0) throw new Error('Playback stopped'); offset += count;
        }
      }
    } catch (_) { await this.stop(); this.onEnded(); }
    finally { this.draining = false; }
  }
  async stop(): Promise<void> {
    this.active = false; this.generation++; this.queue = [];
    const renderer = this.renderer; const session = this.session;
    this.renderer = undefined; this.session = undefined;
    try { await renderer?.stop(); } catch (_) {}
    try { await renderer?.release(); } catch (_) {}
    try { await session?.destroy(); } catch (_) {}
  }
}

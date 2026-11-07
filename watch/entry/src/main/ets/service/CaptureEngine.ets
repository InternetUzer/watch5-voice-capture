/** Platform-independent PCM16/16kHz mono recording policy. All limits count samples. */
export interface CaptureSink {
  begin(startMs: number): void;
  append(pcm: ArrayBuffer, startMs: number, source: string): void;
  finish(): void;
}
export interface PcmFrame {
  pcm: ArrayBuffer;
  startMs: number;
  source: string;
}
export type CaptureMode = 'auto' | 'continuous';
export type Sensitivity = 'low' | 'normal' | 'high';

/** Speech-oriented energy/band detector, NOT a speech recognition model. */
export class SpeechGate {
  private floor: number = 100;
  private candidateSamples: number = 0;
  private tailSamples: number = 0;
  private previousInput: number = 0;
  private previousHigh: number = 0;
  private previousLow: number = 0;
  sensitivity: Sensitivity = 'normal';

  reset(): void {
    this.floor = 100; this.candidateSamples = 0; this.tailSamples = 0;
    this.previousInput = 0; this.previousHigh = 0; this.previousLow = 0;
  }

  feed(pcm: ArrayBuffer): boolean {
    const samples = new Int16Array(pcm);
    let energy: number = 0;
    let bandEnergy: number = 0;
    let crossings: number = 0;
    let previous: number = this.previousLow;
    for (let i = 0; i < samples.length; i++) {
      // First-order 160 Hz high pass, 3.4 kHz low pass; reject rumble and clicks.
      const high = 0.941 * (this.previousHigh + samples[i] - this.previousInput);
      const low = this.previousLow + 0.737 * (high - this.previousLow);
      this.previousInput = samples[i]; this.previousHigh = high; this.previousLow = low;
      energy += samples[i] * samples[i]; bandEnergy += low * low;
      if ((low >= 0) !== (previous >= 0)) crossings++;
      previous = low;
    }
    const rms = Math.sqrt(bandEnergy / Math.max(1, samples.length));
    const minimum = this.sensitivity === 'high' ? 140 : (this.sensitivity === 'low' ? 600 : 280);
    const multiplier = this.sensitivity === 'high' ? 1.8 : (this.sensitivity === 'low' ? 3.5 : 2.5);
    const crossingRate = crossings / Math.max(1, samples.length);
    const likelySpeech = rms > Math.max(minimum, this.floor * multiplier) &&
      bandEnergy > energy * 0.12 && crossingRate > 0.005 && crossingRate < 0.45;
    if (this.tailSamples === 0 && !likelySpeech) {
      this.floor = Math.min(500, Math.max(25, this.floor * 0.99 + rms * 0.01));
    }
    if (likelySpeech) {
      this.candidateSamples += samples.length;
      if (this.tailSamples > 0 || this.candidateSamples >= 960) this.tailSamples = 80000;
      return this.tailSamples > 0;
    }
    this.candidateSamples = 0;
    const wasActive = this.tailSamples > 0;
    this.tailSamples = Math.max(0, this.tailSamples - samples.length);
    return wasActive;
  }
}

export class CaptureEngine {
  readonly maxBytes: number = 16000 * 2 * 600;
  readonly gate: SpeechGate = new SpeechGate();
  mode: CaptureMode = 'auto';
  private sink: CaptureSink;
  private prior: PcmFrame[] = [];
  private priorBytes: number = 0;
  private currentBytes: number = 0;
  private carry: ArrayBuffer = new ArrayBuffer(0);
  private carryStart: number = 0;
  private carrySource: string = '';
  private writing: boolean = false;
  private lastEnd: number = 0;
  private lastSource: string = "";

  constructor(sink: CaptureSink) { this.sink = sink; }
  recordedMs(): number { return this.currentBytes / 32; }
  isWriting(): boolean { return this.writing; }

  feed(pcm: ArrayBuffer, startMs: number, source: string = 'watch'): void {
    if (pcm.byteLength % 2 !== 0) throw new Error('PCM16 must contain whole samples');
    if (pcm.byteLength === 0) return;
    if (this.lastEnd > 0 && (source !== this.lastSource || Math.abs(startMs - this.lastEnd) > 100)) {
      this.flushCarry(); this.prior = []; this.priorBytes = 0; this.gate.reset();
    }
    this.lastEnd = startMs + pcm.byteLength / 32; this.lastSource = source;
    const merged = new Uint8Array(this.carry.byteLength + pcm.byteLength);
    merged.set(new Uint8Array(this.carry)); merged.set(new Uint8Array(pcm), this.carry.byteLength);
    const firstMs = this.carry.byteLength > 0 ? this.carryStart : startMs;
    let offset = 0;
    while (offset + 640 <= merged.byteLength) {
      this.process({ pcm: merged.buffer.slice(offset, offset + 640), startMs: firstMs + offset / 32, source: source });
      offset += 640;
    }
    this.carry = merged.buffer.slice(offset);
    this.carryStart = firstMs + offset / 32; this.carrySource = source;
  }

  private process(frame: PcmFrame): void {
    this.writing = this.mode === 'continuous' || this.gate.feed(frame.pcm);
    if (this.writing) {
      for (const previous of this.prior) this.write(previous);
      this.prior = []; this.priorBytes = 0;
      this.write(frame);
    } else {
      this.prior.push(frame); this.priorBytes += frame.pcm.byteLength;
      while (this.priorBytes > 64000) {
        const oldest = this.prior.shift();
        if (oldest) this.priorBytes -= oldest.pcm.byteLength;
      }
    }
  }

  private write(frame: PcmFrame): void {
    let offset = 0;
    while (offset < frame.pcm.byteLength) {
      if (this.currentBytes === 0) this.sink.begin(frame.startMs + offset / 32);
      const take = Math.min(this.maxBytes - this.currentBytes, frame.pcm.byteLength - offset);
      this.sink.append(frame.pcm.slice(offset, offset + take), frame.startMs + offset / 32, frame.source);
      this.currentBytes += take; offset += take;
      if (this.currentBytes === this.maxBytes) {
        this.sink.finish(); this.currentBytes = 0;
      }
    }
  }

  private flushCarry(): void {
    if (this.carry.byteLength > 0 && (this.writing || this.mode === 'continuous')) {
      this.write({ pcm: this.carry, startMs: this.carryStart, source: this.carrySource });
    }
    this.carry = new ArrayBuffer(0);
  }

  stop(): void {
    this.flushCarry();
    if (this.currentBytes > 0) { this.sink.finish(); this.currentBytes = 0; }
    this.prior = []; this.priorBytes = 0; this.writing = false; this.lastEnd = 0; this.lastSource = ""; this.gate.reset();
  }
}

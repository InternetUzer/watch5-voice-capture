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

/** Detection is injected so recording/timeline policy can be tested independently. */
export interface VoiceDetector {
  detect(pcm: ArrayBuffer, sensitivity: Sensitivity): boolean;
  reset(): void;
  close(): void;
}

export class SpeechGate {
  private detector: VoiceDetector;
  private candidateSamples: number = 0;
  private candidateGap: number = 0;
  private tailSamples: number = 0;
  sensitivity: Sensitivity = 'high';
  levelRms: number = 0;
  speechDetected: boolean = false;

  constructor(detector: VoiceDetector) { this.detector = detector; }

  reset(): void {
    this.detector.reset();
    this.candidateSamples = 0; this.candidateGap = 0; this.tailSamples = 0;
    this.levelRms = 0; this.speechDetected = false;
  }

  close(): void { this.detector.close(); }

  feed(pcm: ArrayBuffer, detectSpeech: boolean = true): boolean {
    const samples = new Int16Array(pcm);
    let energy: number = 0;
    for (let i = 0; i < samples.length; i++) energy += samples[i] * samples[i];
    this.levelRms = Math.sqrt(energy / Math.max(1, samples.length));
    // Continuous mode needs only the meter; avoid unnecessary VAD work.
    this.speechDetected = detectSpeech && this.detector.detect(pcm, this.sensitivity);
    if (this.speechDetected) {
      this.candidateSamples += samples.length;
      this.candidateGap = 0;
      const onset = this.sensitivity === 'high' ? 320 : (this.sensitivity === 'low' ? 960 : 640);
      if (this.tailSamples > 0 || this.candidateSamples >= onset) this.tailSamples = 80000;
      return this.tailSamples > 0;
    }
    this.candidateGap += samples.length;
    if (this.candidateGap > 640) this.candidateSamples = 0;
    const wasActive = this.tailSamples > 0;
    this.tailSamples = Math.max(0, this.tailSamples - samples.length);
    return wasActive;
  }
}

export class CaptureEngine {
  readonly maxBytes: number = 16000 * 2 * 600;
  readonly gate: SpeechGate;
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

  constructor(sink: CaptureSink, detector: VoiceDetector) { this.sink = sink; this.gate = new SpeechGate(detector); }
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
    const detected = this.gate.feed(frame.pcm, this.mode === 'auto');
    this.writing = this.mode === 'continuous' || detected;
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
    try {
      this.flushCarry();
      if (this.currentBytes > 0) { this.sink.finish(); this.currentBytes = 0; }
    } finally {
      this.prior = []; this.priorBytes = 0; this.writing = false; this.lastEnd = 0; this.lastSource = '';
      try { this.gate.reset(); } finally { this.gate.close(); }
    }
  }
}

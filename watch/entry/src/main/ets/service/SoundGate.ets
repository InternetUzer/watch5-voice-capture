/** Energy-based sound detector (not speech recognition). Input: PCM16 16 kHz mono. */
export interface SoundGateResult {
  opened: boolean;
  closed: boolean;
  rms: number;
}

export class SoundGate {
  private noiseFloor: number = 180;
  private active: boolean = false;
  private aboveCount: number = 0;
  private belowMs: number = 0;
  private readonly activationFrames: number = 3;
  private thresholdMultiplier: number;
  private minRms: number;
  private closeAfterMs: number;

  constructor(thresholdMultiplier: number = 2.8, minRms: number = 360, closeAfterMs: number = 15000) {
    this.thresholdMultiplier = thresholdMultiplier;
    this.minRms = minRms;
    this.closeAfterMs = closeAfterMs;
  }

  reset(): void {
    this.noiseFloor = 180;
    this.active = false;
    this.aboveCount = 0;
    this.belowMs = 0;
  }

  isActive(): boolean {
    return this.active;
  }

  feed(buffer: ArrayBuffer): SoundGateResult {
    const samples = new Int16Array(buffer);
    let sum: number = 0;
    for (let i: number = 0; i < samples.length; i++) {
      sum += samples[i] * samples[i];
    }

    const rms: number = Math.sqrt(sum / Math.max(1, samples.length));
    const durationMs: number = samples.length * 1000 / 16000;
    const loud: boolean = rms > Math.max(this.minRms, this.noiseFloor * this.thresholdMultiplier);
    let opened: boolean = false;
    let closed: boolean = false;

    if (!this.active) {
      if (!loud) {
        this.noiseFloor = this.noiseFloor * 0.96 + rms * 0.04;
      }
      this.aboveCount = loud ? this.aboveCount + 1 : 0;
      if (this.aboveCount >= this.activationFrames) {
        this.active = true;
        this.belowMs = 0;
        opened = true;
      }
    } else {
      this.belowMs = loud ? 0 : this.belowMs + durationMs;
      if (this.belowMs >= this.closeAfterMs) {
        this.active = false;
        this.aboveCount = 0;
        this.belowMs = 0;
        closed = true;
      }
    }

    const result: SoundGateResult = { opened: opened, closed: closed, rms: rms };
    return result;
  }
}

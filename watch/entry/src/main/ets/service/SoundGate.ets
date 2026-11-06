/** Simple energy-based detector, not voice recognition. PCM16 16kHz mono. */
export class SoundGate {
  private noiseFloor: number = 180;
  private active: boolean = false;
  private aboveCount: number = 0;
  private belowMs: number = 0;
  private readonly activationFrames: number = 3;
  constructor(private thresholdMultiplier: number = 2.8, private minRms: number = 360, private closeAfterMs: number = 15000) {}
  reset(): void { this.noiseFloor = 180; this.active = false; this.aboveCount = 0; this.belowMs = 0; }
  isActive(): boolean { return this.active; }
  feed(buffer: ArrayBuffer): { opened: boolean; closed: boolean; rms: number } {
    const samples = new Int16Array(buffer);
    let sum = 0;
    for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
    const rms = Math.sqrt(sum / Math.max(1, samples.length));
    const durationMs = samples.length * 1000 / 16000;
    const loud = rms > Math.max(this.minRms, this.noiseFloor * this.thresholdMultiplier);
    let opened = false;
    let closed = false;
    if (!this.active) {
      if (!loud) this.noiseFloor = this.noiseFloor * 0.96 + rms * 0.04;
      this.aboveCount = loud ? this.aboveCount + 1 : 0;
      if (this.aboveCount >= this.activationFrames) { this.active = true; this.belowMs = 0; opened = true; }
    } else {
      this.belowMs = loud ? 0 : this.belowMs + durationMs;
      if (this.belowMs >= this.closeAfterMs) { this.active = false; this.aboveCount = 0; this.belowMs = 0; closed = true; }
    }
    return { opened, closed, rms };
  }
}
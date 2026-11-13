export class WebRtcVad {
  constructor(mode: number);
  /** Exactly 320 PCM16 LE mono samples at 16 kHz. */
  process(pcm: ArrayBuffer): boolean;
  reset(mode: number): void;
  /** Idempotent. This instance cannot be reused after close. */
  close(): void;
}

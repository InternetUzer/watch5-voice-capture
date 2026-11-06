import { fileIo as fs } from '@kit.CoreFileKit';
/** PCM16 mono 16kHz WAV writer. */
export class WavWriter {
  private file?: fs.File;
  private samplesBytes: number = 0;
  readonly path: string;
  dataBytes(): number { return this.samplesBytes; }
  constructor(path: string) {
    this.path = path;
    this.file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(this.file.fd, new ArrayBuffer(44));
  }
  append(data: ArrayBuffer): void {
    if (!this.file) return;
    this.samplesBytes += fs.writeSync(this.file.fd, data);
  }
  close(): void {
    if (!this.file) return;
    const header = new ArrayBuffer(44);
    const v = new DataView(header);
    const chars = (s: string, o: number): void => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
    chars('RIFF', 0); v.setUint32(4, 36 + this.samplesBytes, true);
    chars('WAVE', 8); chars('fmt ', 12); v.setUint32(16, 16, true);
    v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, 16000, true); v.setUint32(28, 32000, true);
    v.setUint16(32, 2, true); v.setUint16(34, 16, true);
    chars('data', 36); v.setUint32(40, this.samplesBytes, true);
    fs.closeSync(this.file); this.file = undefined;
    const patch = fs.openSync(this.path, fs.OpenMode.READ_WRITE);
    try { fs.writeSync(patch.fd, header); } finally { fs.closeSync(patch); }
  }
}
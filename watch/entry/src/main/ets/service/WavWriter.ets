import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export interface TimelineSegment {
  audio_start_ms: number;
  audio_end_ms: number;
  started_at_ms: number;
  ended_at_ms: number;
  source: string;
}
export interface CaptureTimeline {
  version: number;
  started_at: string;
  timezone_offset_minutes: number;
  recovered: boolean;
  segments: TimelineSegment[];
}

/** A .part file is never uploadable. Its header checkpoints the durable PCM length. */
export class WavWriter {
  private file?: fs.File;
  private samplesBytes: number = 0;
  private lastCheckpoint: number = 0;
  private timeline: CaptureTimeline;
  readonly path: string;

  constructor(path: string, startMs: number, recovering: boolean = false) {
    this.path = path;
    this.timeline = { version: 1, started_at: new Date(startMs).toISOString(),
      timezone_offset_minutes: -new Date(startMs).getTimezoneOffset(), recovered: recovering, segments: [] };
    try {
    if (recovering) {
      this.file = fs.openSync(path + '.part', fs.OpenMode.READ_WRITE);
      const header = new ArrayBuffer(44);
      let count = 0;
      while (count < 44) {
        const piece = new ArrayBuffer(44 - count);
        const read = fs.readSync(this.file.fd, piece, { offset: count });
        if (read <= 0) throw new Error('Incomplete checkpoint header');
        new Uint8Array(header).set(new Uint8Array(piece, 0, read), count); count += read;
      }
      const view = new DataView(header);
      if (view.getUint32(0, false) !== 0x52494646 || view.getUint32(8, false) !== 0x57415645 ||
        view.getUint32(36, false) !== 0x64617461 || view.getUint32(24, true) !== 16000 ||
        (view.getUint32(40, true) === 0 && fs.statSync(path + '.part').size > 44)) {
        throw new Error('Invalid checkpoint; preserve original for recovery');
      }
      this.samplesBytes = Math.min(new DataView(header).getUint32(40, true),
        Math.max(0, fs.statSync(path + '.part').size - 44), 19200000);
      this.samplesBytes -= this.samplesBytes % 2;
      try {
        this.timeline = JSON.parse(fs.readTextSync(path + '.journal')) as CaptureTimeline;
      } catch (_) {}
      this.timeline.recovered = true;
      this.timeline.segments = this.timeline.segments.filter((s: TimelineSegment) => s.audio_end_ms <= this.samplesBytes / 32);
      fs.truncateSync(this.file.fd, 44 + this.samplesBytes);
    } else {
      // The recorder is the only writer; this synchronous check/create cannot
      // interleave with another recording callback. Never overwrite a checkpoint.
      if (fs.accessSync(path + '.part') || fs.accessSync(path)) throw new Error('Recording already exists');
      this.file = fs.openSync(path + '.part', fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      this.writeAt(this.header(0), 0);
      this.checkpoint();
    }
    } catch (error) { this.abandonHandle(); throw error as Error; }
  }

  dataBytes(): number { return this.samplesBytes; }

  private writeAt(bytes: ArrayBuffer, position: number): void {
    if (!this.file) throw new Error('WAV is closed');
    let written = 0;
    while (written < bytes.byteLength) {
      const count = fs.writeSync(this.file.fd, bytes.slice(written), { offset: position + written });
      if (count <= 0) throw new Error('No space for recording');
      written += count;
    }
  }

  append(data: ArrayBuffer, startMs: number, source: string): void {
    const offsetMs = this.samplesBytes / 32;
    this.writeAt(data, 44 + this.samplesBytes);
    this.samplesBytes += data.byteLength;
    const last = this.timeline.segments[this.timeline.segments.length - 1];
    const duration = data.byteLength / 32;
    if (last && last.source === source && Math.abs(last.ended_at_ms - startMs) < 0.1) {
      last.audio_end_ms += duration; last.ended_at_ms += duration;
    } else {
      this.timeline.segments.push({ audio_start_ms: offsetMs, audio_end_ms: offsetMs + duration,
        started_at_ms: startMs, ended_at_ms: startMs + duration, source: source });
    }
    // Update PCM length even between journal checkpoints; recovery never sends a corrupt header.
    const size = new ArrayBuffer(4); new DataView(size).setUint32(0, this.samplesBytes, true);
    this.writeAt(size, 40);
    if (this.samplesBytes - this.lastCheckpoint >= 32000) this.checkpoint();
  }

  private checkpoint(): void {
    if (!this.file) return;
    fs.fsyncSync(this.file.fd);
    const temp = fs.openSync(this.path + '.journal.tmp', fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    try {
      const bytes = new util.TextEncoder().encodeInto(JSON.stringify(this.timeline));
      let offset = 0;
      while (offset < bytes.byteLength) {
        const n = fs.writeSync(temp.fd, bytes.buffer.slice(offset));
        if (n <= 0) throw new Error('Cannot save timeline');
        offset += n;
      }
      fs.fsyncSync(temp.fd);
    } finally { fs.closeSync(temp); }
    fs.renameSync(this.path + '.journal.tmp', this.path + '.journal');
    this.lastCheckpoint = this.samplesBytes;
  }

  private header(extra: number): ArrayBuffer {
    const header = new ArrayBuffer(44); const v = new DataView(header);
    const chars = (s: string, o: number): void => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
    chars('RIFF', 0); v.setUint32(4, 36 + this.samplesBytes + extra, true);
    chars('WAVE', 8); chars('fmt ', 12); v.setUint32(16, 16, true);
    v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, 16000, true); v.setUint32(28, 32000, true);
    v.setUint16(32, 2, true); v.setUint16(34, 16, true);
    chars('data', 36); v.setUint32(40, this.samplesBytes, true); return header;
  }

  close(): void {
    if (!this.file) return;
    if (this.samplesBytes === 0) {
      fs.closeSync(this.file); this.file = undefined; fs.unlinkSync(this.path + '.part');
      try { fs.unlinkSync(this.path + '.journal'); } catch (_) {}
      return;
    }
    this.checkpoint();
    const json = new util.TextEncoder().encodeInto(JSON.stringify(this.timeline));
    const extra = new ArrayBuffer(8 + json.byteLength + json.byteLength % 2);
    const view = new DataView(extra);
    view.setUint32(0, 0x70616376, true); // RIFF 'vcap' chunk
    view.setUint32(4, json.byteLength, true); new Uint8Array(extra).set(json, 8);
    this.writeAt(extra, 44 + this.samplesBytes);
    this.writeAt(this.header(extra.byteLength), 0);
    fs.fsyncSync(this.file.fd); fs.closeSync(this.file); this.file = undefined;
    fs.renameSync(this.path + '.part', this.path);
    try { fs.unlinkSync(this.path + '.journal'); } catch (_) {}
  }

  abandonHandle(): void {
    if (this.file) { try { fs.closeSync(this.file); } catch (_) {} this.file = undefined; }
  }
}

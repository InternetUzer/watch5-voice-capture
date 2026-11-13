import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { stripTypeScriptTypes } from 'node:module';

const source = stripTypeScriptTypes(fs.readFileSync(new URL('../entry/src/main/ets/service/WavWriter.ets', import.meta.url), 'utf8'))
  .replace(/^import .*;$/gm, '').replace('export class WavWriter', 'class WavWriter');
function writer(maxWrite = Infinity) {
  const shim = {
    OpenMode: { READ_WRITE: fs.constants.O_RDWR, WRITE_ONLY: fs.constants.O_WRONLY,
      CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC },
    accessSync: fs.existsSync,
    openSync: (p, flags) => ({ fd: fs.openSync(p, flags) }),
    closeSync: file => fs.closeSync(file.fd ?? file),
    writeSync: (fd, data, opts) => fs.writeSync(fd, Buffer.from(data), 0, Math.min(data.byteLength, maxWrite), opts?.offset ?? null),
    readSync: (fd, data, opts) => fs.readSync(fd, Buffer.from(data), 0, data.byteLength, opts?.offset ?? null),
    statSync: fs.statSync, readTextSync: p => fs.readFileSync(p, 'utf8'), truncateSync: fs.ftruncateSync,
    renameSync: fs.renameSync, fsyncSync: fs.fsyncSync, unlinkSync: fs.unlinkSync
  };
  class Encoder { encodeInto(s) { return new TextEncoder().encode(s); } }
  return new Function('fs', 'util', source + '; return WavWriter')(shim, { TextEncoder: Encoder });
}
function parse(file) {
  const b = fs.readFileSync(file); const length = b.readUInt32LE(40);
  assert.equal(b.subarray(0, 4).toString(), 'RIFF'); assert.equal(b.readUInt32LE(4), b.length - 8);
  assert.equal(b.subarray(44 + length, 48 + length).toString(), 'vcap');
  const size = b.readUInt32LE(48 + length);
  return { length, meta: JSON.parse(b.subarray(52 + length, 52 + length + size)) };
}
test('partial writes, correct RIFF header, real-world time gaps, and atomic upload readiness', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'watch-wav-'));
  try {
    const filename = path.join(directory, 'capture_1700000000000.wav'); const Writer = writer(127);
    const w = new Writer(filename, 1700000000000);
    w.append(new ArrayBuffer(32000), 1700000000000, 'watch');
    assert.equal(fs.existsSync(filename), false);
    w.append(new ArrayBuffer(32000), 1700001000000, 'watch'); w.close();
    const {length, meta} = parse(filename); assert.equal(length, 64000);
    assert.equal(meta.segments.length, 2); assert.equal(meta.segments[1].audio_start_ms, 1000);
    assert.equal(meta.segments[1].started_at_ms, 1700001000000);
    assert.equal(fs.existsSync(filename + '.part'), false);
  } finally { fs.rmSync(directory, { recursive: true }); }
});
test('crash recovery retains checkpointed PCM and marks incomplete timing explicitly', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'watch-recovery-'));
  try {
    const filename = path.join(directory, 'capture_1700000000000.wav'); const Writer = writer();
    const w = new Writer(filename, 1700000000000);
    w.append(new ArrayBuffer(32000), 1700000000000, 'watch');
    w.append(new ArrayBuffer(640), 1700000001000, 'watch'); w.abandonHandle();
    const recovered = new Writer(filename, 1700000000000, true); recovered.close();
    const {length, meta} = parse(filename); assert.equal(length, 32640); assert.equal(meta.recovered, true);
    assert.equal(meta.segments[0].audio_end_ms, 1000);
  } finally { fs.rmSync(directory, { recursive: true }); }
});

test('corrupt checkpoint header is retained rather than interpreted as empty audio', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'watch-corrupt-'));
  try {
    const file = path.join(directory, 'capture_1700000000000.wav');
    fs.writeFileSync(file + '.part', Buffer.alloc(1000)); const Writer = writer();
    assert.throws(() => new Writer(file, 1700000000000, true), /Invalid checkpoint/);
    assert.equal(fs.statSync(file + '.part').size, 1000);
  } finally { fs.rmSync(directory, {recursive:true}); }
});

test('a new recording cannot overwrite an existing checkpoint or completed file', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'watch-collision-'));
  try {
    const file = path.join(directory, 'capture_1700000000000.wav'); const Writer = writer();
    const original = Buffer.from('preserve original');
    for (const suffix of ['.part', '']) {
      fs.writeFileSync(file + suffix, original);
      assert.throws(() => new Writer(file, 1700000000000), /already exists/);
      assert.deepEqual(fs.readFileSync(file + suffix), original);
      fs.unlinkSync(file + suffix);
    }
  } finally { fs.rmSync(directory, {recursive:true}); }
});

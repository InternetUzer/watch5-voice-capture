import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import { readFileSync } from 'node:fs';

async function load(name) {
  const source = readFileSync(new URL(`../entry/src/main/ets/service/${name}.ets`, import.meta.url), 'utf8');
  return import('data:text/javascript;base64,' + Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
}
const { CaptureEngine } = await load('CaptureEngine');
const { canDeleteRecording } = await load('UploadReceipt');
class Sink {
  clips = []; current;
  begin(start) { this.current = { start, bytes: 0, spans: [] }; this.clips.push(this.current); }
  append(pcm, start, source) { this.current.bytes += pcm.byteLength; this.current.spans.push([start, pcm.byteLength / 32, source]); }
  finish() { this.current = undefined; }
}
const silence = () => new Int16Array(320).buffer;
const speech = () => Int16Array.from({ length: 320 }, (_, i) => Math.sin(i * 2 * Math.PI * 600 / 16000) * 5000).buffer;
function feed(engine, count, firstMs, sound = silence) {
  for (let i = 0; i < count; i++) engine.feed(sound(), firstMs + i * 20);
}

test('silence alone creates no files, including stop', () => {
  const sink = new Sink(), engine = new CaptureEngine(sink);
  feed(engine, 1000, 1700000000000); engine.stop(); assert.equal(sink.clips.length, 0);
});
test('2 second preroll, 5 second tail, silence pauses the SAME ten-minute file', () => {
  const sink = new Sink(), engine = new CaptureEngine(sink), start = 1700000000000;
  feed(engine, 500, start); feed(engine, 100, start + 10000, speech);
  feed(engine, 1000, start + 12000);
  const pausedBytes = sink.clips[0].bytes;
  assert.equal(pausedBytes / 32, 8960); // trigger after 60ms, pre-roll includes 40ms of candidate speech
  assert.equal(sink.current, sink.clips[0]); assert.equal(engine.isWriting(), false);
  feed(engine, 100, start + 32000, speech); engine.stop();
  assert.equal(sink.clips.length, 1); assert.ok(sink.clips[0].bytes > pausedBytes);
  assert.ok(sink.clips[0].spans.some(s => s[0] >= start + 30000));
});
test('exact 10 minute chunks and short remainder without sample loss at arbitrary buffer boundaries', () => {
  const sink = new Sink(), engine = new CaptureEngine(sink); engine.mode = 'continuous';
  const total = 19200000 * 2 + 12346;
  let done = 0;
  while (done < total) {
    const take = Math.min(4094, total - done);
    engine.feed(new ArrayBuffer(take), 1700000000000 + done / 32); done += take;
  }
  engine.stop(); assert.deepEqual(sink.clips.map(x => x.bytes), [19200000, 19200000, 12346]);
});
test('continuous speech spans file boundary without duplicated preroll', () => {
  const sink = new Sink(), engine = new CaptureEngine(sink);
  feed(engine, 30100, 1700000000000, speech); engine.stop();
  assert.deepEqual(sink.clips.map(x => x.bytes), [19200000, 64000]);
});
test('disconnected source cannot leak stale pre-roll into new source', () => {
  const sink = new Sink(), engine = new CaptureEngine(sink);
  feed(engine, 100, 1700000000000);
  for (let i = 0; i < 10; i++) engine.feed(speech(), 1700000100000 + i * 20, 'headset');
  engine.stop(); assert.equal(sink.clips[0].start, 1700000100000);
  assert.ok(sink.clips[0].spans.every(x => x[2] === 'headset'));
});
test('exact final chunk does not create empty file on stop', () => {
  const sink = new Sink(), engine = new CaptureEngine(sink); engine.mode = 'continuous';
  feed(engine, 30000, 1700000000000); engine.stop(); assert.equal(sink.clips.length, 1);
});
test('receipt must prove exact file and cloud verification before deletion', () => {
  const receipt = { filename: 'capture_1700000000000.wav', bytes: 100, sha256: 'a'.repeat(64),
    cloud_synced: true, cloud_verified: true, cloud_path: 'disk:/record.wav' };
  const check = r => canDeleteRecording(r, receipt.filename, receipt.bytes, receipt.sha256);
  assert.equal(check(receipt), true);
  for (const bad of [{cloud_verified: false}, {cloud_synced: false}, {filename: 'other.wav'},
    {bytes: 99}, {sha256: 'b'.repeat(64)}, {cloud_path: ''}]) assert.equal(check({...receipt, ...bad}), false);
});

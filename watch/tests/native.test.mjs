import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { readFileSync } from 'node:fs';

const addonPath = process.env.WATCH_VAD_ADDON;
if (!addonPath) throw new Error('Run this test with scripts/test-watch-vad.py (native build required)');
const nativeVad = createRequire(import.meta.url)(addonPath);
globalThis.__watchVadNative = nativeVad;
async function load(name) {
  let source = readFileSync(new URL(`../entry/src/main/ets/service/${name}.ets`, import.meta.url), 'utf8');
  if (name === 'WebRtcDetector') {
    source = source.replace("import nativeVad from 'libwatchvad.so';", 'const nativeVad = globalThis.__watchVadNative;')
      .replace("import { Sensitivity, VoiceDetector } from './CaptureEngine';", '');
  }
  return import('data:text/javascript;base64,' + Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
}
const { CaptureEngine } = await load('CaptureEngine');
const { WebRtcDetector } = await load('WebRtcDetector');
const raw = Buffer.from(readFileSync(new URL('./fixtures/webrtc-test-audio.raw.base64', import.meta.url), 'utf8'), 'base64');
// Test-only 2x sample repetition. Production microphone supplies 16kHz directly.
const voice = new Int16Array(raw.length);
for (let i = 0; i < raw.length / 2; i++) voice[i * 2] = voice[i * 2 + 1] = raw.readInt16LE(i * 2);
const frames = [];
for (let i = 0; i + 320 <= voice.length; i += 320) frames.push(voice.slice(i, i + 320).buffer);

test('native bridge validates mode, receiver, PCM frame size and closed lifecycle', () => {
  for (const mode of [-1, 4, 0.5, NaN, Infinity, '0', undefined]) assert.throws(() => new nativeVad.WebRtcVad(mode));
  assert.throws(() => nativeVad.WebRtcVad(0));
  const vad = new nativeVad.WebRtcVad(0);
  for (const pcm of [null, undefined, new Uint8Array(640), new ArrayBuffer(0), new ArrayBuffer(639), new ArrayBuffer(642)])
    assert.throws(() => vad.process(pcm));
  assert.throws(() => vad.process.call({}, new ArrayBuffer(640)));
  assert.equal(vad.process(new ArrayBuffer(640)), false);
  vad.close(); vad.close();
  assert.throws(() => vad.process(new ArrayBuffer(640)), /closed/);
  assert.throws(() => vad.reset(0), /closed/);
});

test('real audio triggers native VAD, silence stays quiet, reset is deterministic and instances are isolated', () => {
  const active = new nativeVad.WebRtcVad(0), quiet = new nativeVad.WebRtcVad(0);
  const first = frames.map(frame => active.process(frame));
  assert.ok(first.some(Boolean));
  for (let i = 0; i < 1000; i++) assert.equal(quiet.process(new ArrayBuffer(640)), false);
  active.reset(0);
  assert.deepEqual(frames.map(frame => active.process(frame)), first);
  active.close(); quiet.close();
});

test('ArkTS adapter maps sensitivity, resets, releases and can restart', () => {
  for (const [sensitivity, mode] of [['high', 0], ['normal', 1], ['low', 2]]) {
    const adapter = new WebRtcDetector(), direct = new nativeVad.WebRtcVad(mode);
    const expected = frames.map(frame => direct.process(frame));
    assert.deepEqual(frames.map(frame => adapter.detect(frame, sensitivity)), expected);
    adapter.reset(); assert.deepEqual(frames.map(frame => adapter.detect(frame, sensitivity)), expected);
    adapter.close(); adapter.close();
    assert.deepEqual(frames.map(frame => adapter.detect(frame, sensitivity)), expected);
    adapter.close(); direct.close();
  }
});

test('quiet copies of real speech still trigger the sensitive preset', () => {
  for (const gain of [0.25, 0.1]) {
    const adapter = new WebRtcDetector();
    const decisions = frames.map(frame => {
      const quiet = Int16Array.from(new Int16Array(frame), sample => Math.round(sample * gain));
      return adapter.detect(quiet.buffer, 'high');
    });
    assert.ok(decisions.some(Boolean), `gain ${gain}`);
    adapter.close();
  }
});

test('real WebRTC + ArkTS capture policy records voice, preserves samples/timestamps and pauses after tail', () => {
  let bytes = 0, opened = 0, closed = 0;
  const spans = [];
  const sink = {begin() { opened++; }, append(pcm, start, source) { bytes += pcm.byteLength; spans.push([start, pcm.byteLength, source]); }, finish() { closed++; }};
  const engine = new CaptureEngine(sink, new WebRtcDetector());
  const start = 1700000000000;
  let time = start;
  const feed = pcm => { engine.feed(pcm, time); time += pcm.byteLength / 32; };
  for (let i = 0; i < 150; i++) feed(new ArrayBuffer(640));
  assert.equal(opened, 0);
  for (const frame of frames) feed(frame);
  assert.equal(opened, 1); assert.equal(engine.isWriting(), true);
  for (let i = 0; i < 400; i++) feed(new ArrayBuffer(640));
  assert.equal(engine.isWriting(), false);
  const pausedBytes = bytes;
  for (let i = 0; i < 50; i++) feed(new ArrayBuffer(640));
  assert.equal(bytes, pausedBytes);
  for (const frame of frames) feed(frame);
  assert.ok(bytes > pausedBytes);
  engine.stop(); assert.equal(closed, 1);
  assert.ok(spans[0][0] >= start + 1000 && spans[0][0] < start + 3000, 'pre-roll retains audio before speech');
  assert.ok(spans.some((s, i) => i > 0 && s[0] > spans[i - 1][0] + spans[i - 1][1] / 32), 'real clock gap remains visible');
});

test('native allocation/close cycles are repeatable', () => {
  for (let i = 0; i < 2000; i++) {
    const vad = new nativeVad.WebRtcVad(i % 4);
    vad.process(frames[0]); vad.close();
  }
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
function load(name, dependencies = {}) {
  const source = stripTypeScriptTypes(fs.readFileSync(new URL(`../entry/src/main/ets/service/${name}.ets`, import.meta.url), 'utf8'))
    .replace(/^import .*;$/gm, '').replace(/export (class|function) /g, '$1 ');
  return new Function(...Object.keys(dependencies), source + `; return ${name === 'LiveProtocol' ? 'decodeLiveFrame' : name};`)(...Object.values(dependencies));
}
const decodeLiveFrame = load('LiveProtocol');
const encoder = new TextEncoder();
function packet(sequence = 1) {
  const bytes = new Uint8Array(24 + 3200); const v = new DataView(bytes.buffer);
  bytes.set(encoder.encode('WV2A')); v.setUint32(4, 7, true); v.setUint32(8, sequence, true);
  v.setFloat64(12, 1700000000000, true); v.setUint32(20, 3200, true); return bytes;
}
test('live frames validate exact length, offset views, timestamps and PCM alignment', () => {
  const bytes = packet(); const framed = new Uint8Array(bytes.length + 10); framed.set(bytes, 5);
  assert.equal(decodeLiveFrame(framed.subarray(5, -5)).pcm.byteLength, 3200);
  assert.equal(decodeLiveFrame(bytes.subarray(0, -1)), undefined);
  new DataView(bytes.buffer).setFloat64(12, NaN, true); assert.equal(decodeLiveFrame(bytes), undefined);
  const odd = packet(); new DataView(odd.buffer).setUint32(20, 3199, true); assert.equal(decodeLiveFrame(odd), undefined);
});
function link() {
  class Decoder { static create() { return { decodeWithStream: b => new TextDecoder().decode(b) }; } }
  class Encoder { encodeInto(s) { return encoder.encode(s); } }
  const Link = load('CompanionLink', { util: { TextDecoder: Decoder, TextEncoder: Encoder }, decodeLiveFrame,
    wearEngine: { P2pResultCode: { COMMUNICATION_SUCCESS: 207 } }, fs: {}, canIUse: () => true });
  const value = new Link();
  const state = { type: 'status', session: 7, id: 0, source_available: true, stopped: false,
    mode: 'listen', listening: false, elapsed_ms: 0, queue: 0, upload: '', source: 'headset' };
  const receive = s => value.receive({ content: encoder.encode(JSON.stringify(s)) });
  receive(state); value.peer = 'phone';
  return { value, state, receive };
}
test('live session and increasing sequence reject duplicate and stale audio', () => {
  const {value} = link(); let count = 0; value.onAudio = () => count++;
  value.receive({content: packet(2)}); value.receive({content: packet(2)}); value.receive({content: packet(1)});
  const stale = packet(3); new DataView(stale.buffer).setUint32(4, 6, true); value.receive({content: stale});
  assert.equal(count, 1);
});
test('full-state commands only finish after matching session acknowledgement', async () => {
  const {value, state, receive} = link();
  value.client = { sendMessage: async (_peer, _app, message) => {
    const command = JSON.parse(new TextDecoder().decode(message.content));
    receive({...state, id: command.id, stopped: command.stop}); return {code: 207};
  }};
  await value.command('auto', 'normal', true); const first = value.commandId;
  await value.command('listen', 'normal', false, true);
  assert.ok(value.commandId > first); assert.equal(value.stopPending(), false); assert.equal(value.ready(), false);
});
test('file accepted by phone is not a cloud receipt', async () => {
  const {value} = link();
  value.client = {sendMessage: async (_peer, _app, message) => {
    const query = JSON.parse(new TextDecoder().decode(message.content));
    value.receive({content: encoder.encode(JSON.stringify({...query, type:'relay', accepted:true, need_file:false}))});
    return {code:207};
  }};
  await assert.rejects(value.relayFile('/unused', 'capture_1700000000000.wav', 100, 'a'.repeat(64), () => {}), /Awaiting cloud receipt/);
});

test('relay polling observes a later callback and ignores another file reply', async () => {
  const { value, receive } = link();
  const name = 'capture_1700000000000.wav', hash = 'a'.repeat(64);
  const receipt = { filename: name, bytes: 100, sha256: hash,
    cloud_synced: true, cloud_verified: true, cloud_path: 'disk:/test.wav' };
  let timer;
  value.client = { sendMessage: async () => {
    receive({ type: 'relay', filename: 'capture_1700000000001.wav', bytes: 100, sha256: hash });
    timer = setTimeout(() => receive({ type: 'relay', filename: name, bytes: 100,
      sha256: hash, accepted: true, need_file: false, receipt }), 10);
    return { code: 207 };
  } };
  try {
    assert.deepEqual(await value.relayFile('/unused', name, 100, hash, () => {}), receipt);
  } finally { clearTimeout(timer); }
});

test('explicit phone STOP is different from losing the headset source', () => {
  const {value, state, receive} = link();
  receive({...state, source_available:false}); assert.equal(value.sourceLost(), true);
  receive({...state, source_available:false, stopped:true});
  assert.equal(value.sourceLost(), false); assert.equal(value.stopped(), true);
});

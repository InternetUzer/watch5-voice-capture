import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import fs from 'node:fs';

function load(name, dependencies = {}) {
  const source = stripTypeScriptTypes(fs.readFileSync(new URL(`../entry/src/main/ets/service/${name}.ets`, import.meta.url), 'utf8'))
    .replace(/^import .*;$/gm, '').replace(/export (class|function) /g, '$1 ');
  return new Function(...Object.keys(dependencies), source + `; return ${name === 'UploadReceipt' ? 'canDeleteRecording' : name};`)(...Object.values(dependencies));
}
const canDeleteRecording = load('UploadReceipt');
const filename = 'capture_1700000000000.wav';
const digest = 'abcdef0123456789'.repeat(4);
const config = { endpoint: 'https://example.test/v1/recordings', key: 'test-only' };
function setup({ online = true, verified = true, receiptHash = digest, listenerThrows = false, responseCode = 201, requestError, responseBody } = {}) {
  let exists = true, registered = 0, unregistered = 0, destroyed = 0, requests = 0;
  const receipt = { filename, bytes: 44, sha256: receiptHash, cloud_synced: true,
    cloud_verified: verified, cloud_path: 'disk:/test.wav' };
  const net = {
    on: () => {},
    register: callback => {
      assert.equal(typeof callback, 'function'); registered++;
      if (listenerThrows) throw new Error('registration unavailable');
      callback(undefined); // HarmonyOS API returns void.
    },
    unregister: callback => {
      assert.equal(typeof callback, 'function'); unregistered++;
      if (listenerThrows) throw new Error('unregistration unavailable');
      callback(undefined);
    }
  };
  const Uploader = load('Uploader', {
    fs: {
      listFileSync: () => exists ? [filename] : [], statSync: () => ({ size: 44 }),
      OpenMode: { READ_ONLY: 0 }, openSync: () => ({ fd: 1 }), closeSync: () => {},
      readSync: (_fd, piece) => piece.byteLength, unlinkSync: () => { exists = false; }
    },
    fileHash: { hash: async (_path, algorithm) => {
      assert.equal(algorithm, 'sha256'); return digest.toUpperCase();
    } },
    connection: { createNetConnection: () => net, hasDefaultNetSync: () => online },
    http: { RequestMethod: { POST: 'POST' }, createHttp: () => ({
      on: () => {}, off: () => {}, destroy: () => { destroyed++; },
      request: async () => { requests++; if (requestError) throw requestError; return { responseCode, result: responseBody ?? JSON.stringify(receipt) }; }
    }) },
    DeferredUpload: { ensure: async () => {} }, canDeleteRecording
  });
  const uploader = new Uploader(); uploader.initialize({ filesDir: '/sandbox' });
  return { uploader, receipt, exists: () => exists,
    requests: () => requests, calls: () => ({ registered, unregistered, destroyed }) };
}

test('callback-only network API and uppercase native SHA accept an exact verified cloud receipt', async () => {
  const s = setup();
  try {
    await s.uploader.uploadOne(filename, config);
    assert.equal(s.exists(), false);
  } finally { s.uploader.close(); }
  assert.deepEqual(s.calls(), { registered: 1, unregistered: 1, destroyed: 1 });
});

test('normalizing local SHA never permits deletion for unverified or mismatched cloud receipts', async () => {
  for (const options of [{ verified: false }, { receiptHash: '0'.repeat(64) }]) {
    const s = setup(options);
    try {
      await assert.rejects(s.uploader.uploadOne(filename, config), /HTTP 201/);
      assert.equal(s.exists(), true);
    } finally { s.uploader.close(); }
    assert.equal(s.calls().destroyed, 1);
  }
});

test('offline relay receives lowercase SHA and deletes only after verified receipt', async () => {
  for (const verified of [false, true]) {
    const s = setup({ online: false, verified }); let relayed = 0;
    s.uploader.config = config;
    s.uploader.relayAvailable = () => true;
    s.uploader.relay = async (_path, name, size, sha) => {
      relayed++; assert.equal(name, filename); assert.equal(size, 44); assert.equal(sha, digest);
      return s.receipt;
    };
    try {
      await s.uploader.run();
      assert.equal(relayed, 1); assert.equal(s.exists(), !verified);
      assert.equal(s.uploader.sent, verified ? 1 : 0);
    } finally { s.uploader.close(); }
  }
});

test('unavailable network listener does not prevent direct upload or cleanup', async () => {
  const s = setup({ listenerThrows: true });
  await s.uploader.uploadOne(filename, config);
  assert.equal(s.exists(), false);
  s.uploader.close();
  assert.deepEqual(s.calls(), { registered: 1, unregistered: 1, destroyed: 1 });
});


test('background permission failure still attempts foreground upload with a visible notice', async () => {
  const s = setup(); s.uploader.config = config;
  s.uploader.onBusy = async () => { throw { code: 9800004, message: 'private raw error' }; };
  try {
    await s.uploader.run();
    assert.equal(s.requests(), 1); assert.equal(s.exists(), false);
    assert.match(s.uploader.backgroundNotice, /оставь приложение открытым/);
    assert.match(s.uploader.status, /Все записи/);
    assert.ok(s.uploader.lastAttempt);
  } finally { s.uploader.close(); }
});

test('HTTP errors preserve recordings and show the status without server body or keys', async () => {
  for (const responseCode of [401, 403, 404, 413, 422, 429, 502, 503]) {
    const s = setup({ responseCode, responseBody: 'secret-server-body' }); s.uploader.config = config;
    try {
      await s.uploader.run();
      assert.equal(s.exists(), true); assert.equal(s.uploader.sent, 0);
      assert.ok(s.uploader.status.includes(`HTTP ${responseCode}`));
      assert.ok(!s.uploader.status.includes('secret-server-body'));
      assert.ok(!s.uploader.status.includes(config.key));
    } finally { s.uploader.close(); }
  }
});

test('transport errors expose only numeric code and failed stage; invalid receipts never delete', async () => {
  for (const options of [
    { requestError: { code: 2300006, message: 'sensitive-url-or-header' } },
    { responseBody: 'invalid-secret-json' }, { responseBody: 'null' }
  ]) {
    const s = setup(options); s.uploader.config = config;
    try {
      await s.uploader.run(); assert.equal(s.exists(), true);
      assert.ok(!s.uploader.status.includes('sensitive-url-or-header'));
      assert.ok(!s.uploader.status.includes('invalid-secret-json'));
      if (options.requestError) assert.match(s.uploader.status, /2300006/);
      else assert.match(s.uploader.status, /HTTP 201/);
    } finally { s.uploader.close(); }
  }
});

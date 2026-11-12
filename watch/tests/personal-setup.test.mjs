import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

const source = stripTypeScriptTypes(fs.readFileSync(new URL('../entry/src/main/ets/service/PersonalSetup.ets', import.meta.url), 'utf8'))
  .replace(/^import .*;$/gm, '').replace('export class PersonalSetup', 'class PersonalSetup');
const publicConfig = JSON.parse(fs.readFileSync(new URL('../config/companion-release.json', import.meta.url), 'utf8'));
const profile = {
  version: 1, id: '11111111-2222-3333-4444-555555555555',
  endpoint: 'https://voice.metalcarcase.ru/v1/recordings', key: 'dummy-key-for-tests-only',
  phoneBundle: publicConfig.phoneBundle, phoneFingerprint: publicConfig.phoneFingerprint
};
function setup(initial = profile) {
  const saved = []; const values = new Map(); let flushes = 0, failSave = false;
  let resource = initial, readError;
  const SecureConfig = { save: async c => {
    if (failSave) throw new Error('Asset Store unavailable');
    saved.push(c);
  } };
  const util = { TextDecoder: { create: () => ({ decodeWithStream: b => new TextDecoder().decode(b) }) } };
  const PersonalSetup = new Function('SecureConfig', 'util', source + '; return PersonalSetup;')(SecureConfig, util);
  const context = { resourceManager: { getRawFileContent: async name => {
    assert.equal(name, 'personal-setup.json');
    if (readError) throw readError;
    if (resource === undefined) throw { code: 9001005 };
    return new TextEncoder().encode(JSON.stringify(resource));
  } } };
  const pref = {
    get: async (k, fallback) => values.has(k) ? values.get(k) : fallback,
    put: async (k, v) => { values.set(k, v); }, flush: async () => { flushes++; }
  };
  return { PersonalSetup, context, pref, saved, values, flushes: () => flushes,
    setResource: r => { resource = r; }, setReadError: e => { readError = e; },
    setSaveFailure: v => { failSave = v; } };
}

test('personal build imports key to Asset Store and peer identity to preferences exactly once', async () => {
  const s = setup();
  assert.equal(await s.PersonalSetup.apply(s.context, s.pref), true);
  assert.deepEqual(s.saved, [{ endpoint: profile.endpoint, key: profile.key }]);
  assert.equal(s.values.get('phoneBundle'), 'ru.technadzor.app');
  assert.equal(s.values.get('phoneFingerprint'), profile.phoneFingerprint);
  assert.equal(s.values.get('personalSetupId'), profile.id);
  assert.equal(s.values.has('key'), false);
  s.values.set('phoneFingerprint', 'manual-setting');
  assert.equal(await s.PersonalSetup.apply(s.context, s.pref), false);
  assert.equal(s.saved.length, 1); assert.equal(s.flushes(), 1);
  assert.equal(s.values.get('phoneFingerprint'), 'manual-setting');
});

test('a new explicit profile ID allows key rotation without clearing recordings or other settings', async () => {
  const s = setup(); s.values.set('sensitivity', 'high');
  await s.PersonalSetup.apply(s.context, s.pref);
  const updated = { ...profile, id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', key: 'new-dummy-key-tests-only' };
  s.setResource(updated);
  assert.equal(await s.PersonalSetup.apply(s.context, s.pref), true);
  assert.equal(s.saved[1].key, updated.key);
  assert.equal(s.values.get('sensitivity'), 'high');
});

test('ordinary builds without a personal file preserve manual configuration', async () => {
  const s = setup(); s.setResource(undefined); s.values.set('phoneFingerprint', 'manual-setting');
  assert.equal(await s.PersonalSetup.apply(s.context, s.pref), false);
  assert.equal(s.saved.length, 0); assert.equal(s.flushes(), 0);
  assert.equal(s.values.get('phoneFingerprint'), 'manual-setting');
});

test('invalid profiles fail before mutation and parser errors never expose key or source JSON', async () => {
  for (const bad of [null, [], {}, { ...profile, endpoint: 'https://other.test/v1/recordings' },
    { ...profile, phoneFingerprint: 'not-a-fingerprint' }, { ...profile, key: 'short' },
    { ...profile, phoneBundle: 'other.app' }, { ...profile, version: 2 }]) {
    const s = setup(bad);
    await assert.rejects(s.PersonalSetup.apply(s.context, s.pref), e => {
      assert.equal(e.message.includes(profile.key), false); return true;
    });
    assert.equal(s.saved.length, 0); assert.equal(s.values.size, 0);
  }
  const s = setup();
  assert.throws(() => s.PersonalSetup.parse('{"key":"sensitive-test-value",broken'), e => {
    assert.equal(e.message.includes('sensitive-test-value'), false); return true;
  });
});

test('Asset Store failure does not mark profile applied; retry applies it after recovery', async () => {
  const s = setup(); s.setSaveFailure(true);
  await assert.rejects(s.PersonalSetup.apply(s.context, s.pref), /Asset Store/);
  assert.equal(s.values.has('personalSetupId'), false); assert.equal(s.flushes(), 0);
  s.setSaveFailure(false);
  assert.equal(await s.PersonalSetup.apply(s.context, s.pref), true);
});

test('unexpected resource failure is reported instead of silently treated as an ordinary build', async () => {
  const s = setup(); s.setReadError({ code: 9001001, message: profile.key });
  await assert.rejects(s.PersonalSetup.apply(s.context, s.pref), e => {
    assert.equal(e.message.includes(profile.key), false); return true;
  });
  assert.equal(s.saved.length, 0);
});

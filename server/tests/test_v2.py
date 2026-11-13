import asyncio
import hashlib
import json
import struct
import httpx
import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.wsgi import application
from app.wav_metadata import read_timeline
from app.yandex_disk import upload_wav, YandexDiskError


def wav(seconds=1, timeline=None):
    pcm = bytes(int(32000 * seconds))
    extra = b''
    if timeline is not None:
        data = json.dumps(timeline).encode()
        extra = b'vcap' + struct.pack('<I', len(data)) + data + bytes(len(data) % 2)
    return b'RIFF' + struct.pack('<I', 36 + len(pcm) + len(extra)) + b'WAVEfmt ' + struct.pack(
        '<IHHIIHH', 16, 1, 1, 16000, 32000, 2, 16) + b'data' + struct.pack('<I', len(pcm)) + pcm + extra


def timeline():
    return {'version': 1, 'started_at': '2026-11-06T18:00:00Z', 'recovered': False,
            'segments': [{'audio_start_ms': 0, 'audio_end_ms': 1000,
                          'started_at_ms': 1793988000000, 'ended_at_ms': 1793988001000, 'source': 'watch'}]}


@pytest.mark.parametrize('adapter', ['asgi', 'wsgi'])
def test_full_ten_minutes_accepted_and_verified(adapter, tmp_path, monkeypatch):
    import app.main as main
    import app.wsgi as wsgi
    monkeypatch.setenv('WATCH_API_KEY', 'test-key')
    monkeypatch.setenv('YANDEX_DISK_TOKEN', 'fake-token')
    monkeypatch.setenv('WATCH_STORAGE_DIR', str(tmp_path))
    async def cloud(path, name, token, folder):
        assert path.stat().st_size == 19200044
        assert read_timeline(path) is None
        return folder + '/' + name
    monkeypatch.setattr(main if adapter == 'asgi' else wsgi, 'upload_wav', cloud)
    payload = wav(600)
    headers = {'Content-Type': 'audio/wav', 'X-Device-Key': 'test-key'}
    url = '/v1/recordings?filename=capture_1700000000000.wav'
    if adapter == 'asgi':
        result = TestClient(app).post(url, content=payload, headers=headers); metadata = result.json()
    else:
        result = application.test_client().post(url, data=payload, headers=headers); metadata = result.json
    assert result.status_code == 201
    assert metadata['cloud_verified'] is True
    assert metadata['sha256'] == hashlib.sha256(payload).hexdigest()


def test_timeline_is_preserved(tmp_path):
    path = tmp_path / 'record.wav'; path.write_bytes(wav(timeline=timeline()))
    assert read_timeline(path) == timeline()


@pytest.mark.parametrize('kind', ['truncated', 'overlong', 'bad_timeline', 'odd_pcm'])
def test_invalid_wav_cannot_enter_outbox(kind, tmp_path):
    value = wav()
    if kind == 'truncated': value = value[:-1]
    elif kind == 'overlong': value = wav(601)
    elif kind == 'bad_timeline':
        meta = timeline(); meta['segments'][0]['audio_end_ms'] = 2000; value = wav(timeline=meta)
    elif kind == 'odd_pcm':
        value = bytearray(value); struct.pack_into('<I', value, 40, 31999)
    path = tmp_path / 'bad.wav'; path.write_bytes(value)
    with pytest.raises(ValueError): read_timeline(path)


@pytest.mark.parametrize('fail', ['none', 'wrong_hash', 'wrong_size', 'pending_202', 'timeline_failed'])
def test_remote_confirmation_and_timeline_are_required(fail, tmp_path, monkeypatch):
    path = tmp_path / 'record.wav'; path.write_bytes(wav(timeline=timeline()))
    remote = {}; current = ['']; seen = []
    async def no_sleep(_): pass
    monkeypatch.setattr('app.yandex_disk.asyncio.sleep', no_sleep)
    def handler(request):
        seen.append(request)
        if request.url.path.endswith('/resources/upload'):
            current[0] = request.url.params['path']
            return httpx.Response(200, json={'href': 'https://uploader.disk.yandex.ru/upload'})
        if request.url.host == 'uploader.disk.yandex.ru':
            assert 'authorization' not in request.headers
            remote[current[0]] = request.content
            return httpx.Response(202 if fail == 'pending_202' else 201)
        if request.method == 'PUT': return httpx.Response(201)
        if request.method == 'GET':
            name = request.url.params['path']
            if name == 'disk:/Watch5-Voice-Capture': return httpx.Response(200, json={'type':'dir'})
            data = remote[name]
            if fail == 'pending_202' or (fail == 'timeline_failed' and name.endswith('.json')): return httpx.Response(404)
            return httpx.Response(200, json={'type': 'file', 'size': len(data) + (1 if fail == 'wrong_size' else 0),
                'sha256': '0'*64 if fail == 'wrong_hash' else hashlib.sha256(data).hexdigest()})
        return httpx.Response(500)
    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            return await upload_wav(path, 'capture_1700000000000_0123456789ab.wav', 'fake', client=client)
    if fail == 'none':
        assert '/2026-11-06_' in asyncio.run(run())
        assert len(remote) == 2
        assert json.loads(next(data for name, data in remote.items() if name.endswith('.json'))) == timeline()
    else:
        with pytest.raises(YandexDiskError): asyncio.run(run())
    assert path.exists()

def test_write_only_token_is_detected_before_uploading_audio(tmp_path):
    path = tmp_path / 'record.wav'; path.write_bytes(wav())
    seen = []
    def handler(request):
        seen.append(request)
        return httpx.Response(201 if request.method == 'PUT' else 403)
    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            await upload_wav(path, 'capture_1700000000000_0123456789ab.wav', 'fake', client=client)
    with pytest.raises(YandexDiskError, match='read access'):
        asyncio.run(run())
    assert len(seen) == 2
    assert path.exists()

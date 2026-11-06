import struct
from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)
def make_wav():
    payload = b"\x00\x00" * 160
    return b"RIFF" + struct.pack("<I", 36 + len(payload)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16) + b"data" + struct.pack("<I", len(payload)) + payload

def test_health():
    assert client.get('/health').json() == {'status': 'ok'}

def test_auth_required(tmp_path, monkeypatch):
    monkeypatch.setenv('WATCH_API_KEY', 'example-key')
    monkeypatch.setenv('WATCH_STORAGE_DIR', str(tmp_path))
    r = client.post('/v1/recordings?filename=capture_1700000000000.wav', content=make_wav(), headers={'Content-Type': 'audio/wav'})
    assert r.status_code == 401

def test_ingest(tmp_path, monkeypatch):
    monkeypatch.setenv('WATCH_API_KEY', 'example-key')
    monkeypatch.setenv('WATCH_STORAGE_DIR', str(tmp_path))
    r = client.post('/v1/recordings?filename=capture_1700000000000.wav', content=make_wav(), headers={'Content-Type': 'audio/wav', 'X-Device-Key': 'example-key'})
    assert r.status_code == 201, r.text
    info = r.json()
    assert info['bytes'] == len(make_wav())
    assert (tmp_path / f"{info['id']}.wav").exists()
    assert (tmp_path / f"{info['id']}.json").exists()

def test_bad_filename(tmp_path, monkeypatch):
    monkeypatch.setenv('WATCH_API_KEY', 'example-key')
    monkeypatch.setenv('WATCH_STORAGE_DIR', str(tmp_path))
    r = client.post('/v1/recordings?filename=../bad.wav', content=make_wav(), headers={'Content-Type': 'audio/wav', 'X-Device-Key': 'example-key'})
    assert r.status_code == 400

def test_bad_wav(tmp_path, monkeypatch):
    monkeypatch.setenv('WATCH_API_KEY', 'example-key')
    monkeypatch.setenv('WATCH_STORAGE_DIR', str(tmp_path))
    r = client.post('/v1/recordings?filename=capture_1700000000000.wav', content=b'not wave', headers={'Content-Type': 'audio/wav', 'X-Device-Key': 'example-key'})
    assert r.status_code == 422

"""Passenger adapter tests use mock cloud calls, no Yandex credentials."""
import struct

from app.wsgi import application


def wav():
    pcm = b"\x00\x00" * 160
    return (
        b"RIFF" + struct.pack("<I", 36 + len(pcm))
        + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
        + b"data" + struct.pack("<I", len(pcm)) + pcm
    )


def test_wsgi_health():
    with application.test_client() as client:
        assert client.get("/health").json == {"status": "ok"}


def test_wsgi_requires_key(tmp_path, monkeypatch):
    monkeypatch.setenv("WATCH_STORAGE_DIR", str(tmp_path))
    monkeypatch.setenv("WATCH_API_KEY", "secret123")
    with application.test_client() as client:
        resp = client.post("/v1/recordings?filename=capture_1700000000000.wav",
                           data=wav(), content_type="audio/wav")
        assert resp.status_code == 401


def test_wsgi_validates_wav(tmp_path, monkeypatch):
    monkeypatch.setenv("WATCH_STORAGE_DIR", str(tmp_path))
    monkeypatch.setenv("WATCH_API_KEY", "secret123")
    with application.test_client() as client:
        resp = client.post("/v1/recordings?filename=capture_1700000000000.wav",
                           data=b"not a WAV",
                           headers={"X-Device-Key": "secret123"},
                           content_type="audio/wav")
        assert resp.status_code == 422


def test_wsgi_no_yandex_token_keeps_local(tmp_path, monkeypatch):
    monkeypatch.setenv("WATCH_STORAGE_DIR", str(tmp_path))
    monkeypatch.setenv("WATCH_API_KEY", "secret123")
    monkeypatch.delenv("YANDEX_DISK_TOKEN", raising=False)
    with application.test_client() as client:
        resp = client.post("/v1/recordings?filename=capture_1700000000000.wav",
                           data=wav(),
                           headers={"X-Device-Key": "secret123"},
                           content_type="audio/wav")
        assert resp.status_code == 503
        assert len(list(tmp_path.glob("*.wav"))) == 1


def test_wsgi_cloud_upload(tmp_path, monkeypatch):
    import app.wsgi as wsgi
    monkeypatch.setenv("WATCH_STORAGE_DIR", str(tmp_path))
    monkeypatch.setenv("WATCH_API_KEY", "secret123")
    monkeypatch.setenv("YANDEX_DISK_TOKEN", "fake-oauth")
    monkeypatch.setenv("YANDEX_DISK_FOLDER", "disk:/Watch5-Voice-Capture")
    called = []

    async def fake_cloud(path, filename, token, folder):
        called.append((path, filename, token, folder))
        assert path.exists()
        return f"{folder}/{filename}"

    monkeypatch.setattr(wsgi, "upload_wav", fake_cloud)
    with application.test_client() as client:
        resp = client.post("/v1/recordings?filename=capture_1700000000000.wav",
                           data=wav(),
                           headers={"X-Device-Key": "secret123"},
                           content_type="audio/wav")
        assert resp.status_code == 201, resp.get_data(as_text=True)
        assert resp.json["cloud_synced"] is True
        assert len(called) == 1
        assert called[0][2] == "fake-oauth"

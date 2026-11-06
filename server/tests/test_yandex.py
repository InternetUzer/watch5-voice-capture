import asyncio
import hashlib
import struct
from pathlib import Path

import httpx
from fastapi.testclient import TestClient

from app.main import app
from app.yandex_disk import YandexDiskError, upload_wav


def test_upload_to_disk_creates_private_folder_and_uses_signed_url(tmp_path):
    audio = tmp_path / "test.wav"
    audio.write_bytes(b"RIFF" + struct.pack("<I", 38) + b"WAVEfmt " +
        struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16) + b"data" + struct.pack("<I", 2) + b"\x00\x00")
    seen = []

    def handler(request):
        seen.append(request)
        if request.url.path.endswith("/resources"):
            if request.method == "GET":
                return httpx.Response(200, json={"type": "file", "size": audio.stat().st_size,
                    "sha256": hashlib.sha256(audio.read_bytes()).hexdigest()})
            return httpx.Response(201)
        if request.url.path.endswith("/resources/upload"):
            return httpx.Response(200, json={"href": "https://uploader.disk.yandex.ru/upload/test"})
        if request.url.host == "uploader.disk.yandex.ru":
            assert "authorization" not in request.headers
            assert request.content == audio.read_bytes()
            return httpx.Response(201)
        return httpx.Response(500)

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            return await upload_wav(
                audio, "capture_1700000000000_0123456789ab.wav", "test-token",
                "disk:/Watch5-Voice-Capture", client=client,
            )
    path = asyncio.run(run())
    assert path == "disk:/Watch5-Voice-Capture/capture_1700000000000_0123456789ab.wav"
    assert len(seen) == 4
    assert seen[0].headers["Authorization"] == "OAuth test-token"
    assert seen[1].url.params["overwrite"] == "true"


def test_upload_rejects_invalid_folder(tmp_path):
    audio = tmp_path / "test.wav"
    audio.write_bytes(b"RIFF" + struct.pack("<I", 38) + b"WAVEfmt " +
        struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16) + b"data" + struct.pack("<I", 2) + b"\x00\x00")

    async def run():
        await upload_wav(audio, "capture_1700000000000_0123456789ab.wav", "token", "disk:/../bad")
    try:
        asyncio.run(run())
    except YandexDiskError:
        pass
    else:
        raise AssertionError("invalid folder accepted")


def test_server_sync_integration(tmp_path, monkeypatch):
    import struct
    import app.main as main

    monkeypatch.setenv("WATCH_API_KEY", "test-device-key")
    monkeypatch.setenv("WATCH_STORAGE_DIR", str(tmp_path))
    monkeypatch.setenv("YANDEX_DISK_TOKEN", "test-disk-token")
    monkeypatch.setenv("YANDEX_DISK_FOLDER", "disk:/Watch5-Voice-Capture")
    called = []

    async def mock_upload(path, name, token, folder):
        called.append((path, name, token, folder))
        assert Path(path).exists()
        return f"{folder}/{name}"

    monkeypatch.setattr(main, "upload_wav", mock_upload)
    payload = b"\x00\x00" * 160
    wav = b"RIFF" + struct.pack("<I", 36 + len(payload)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16
    ) + b"data" + struct.pack("<I", len(payload)) + payload
    client = TestClient(app)
    res = client.post(
        "/v1/recordings?filename=capture_1700000000000.wav",
        content=wav, headers={"Content-Type": "audio/wav", "X-Device-Key": "test-device-key"}
    )
    assert res.status_code == 201, res.text
    assert res.json()["cloud_synced"] is True
    assert len(called) == 1
    assert called[0][2] == "test-disk-token"


def test_disk_failure_keeps_local_copy(tmp_path, monkeypatch):
    import struct
    import app.main as main

    monkeypatch.setenv("WATCH_API_KEY", "test-device-key")
    monkeypatch.setenv("WATCH_STORAGE_DIR", str(tmp_path))
    monkeypatch.setenv("YANDEX_DISK_TOKEN", "test-disk-token")

    async def bad_upload(*args):
        raise YandexDiskError("simulated cloud failure")

    monkeypatch.setattr(main, "upload_wav", bad_upload)
    payload = b"\x00\x00" * 160
    wav = b"RIFF" + struct.pack("<I", 36 + len(payload)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16
    ) + b"data" + struct.pack("<I", len(payload)) + payload
    res = TestClient(app).post(
        "/v1/recordings?filename=capture_1700000000000.wav",
        content=wav, headers={"Content-Type": "audio/wav", "X-Device-Key": "test-device-key"}
    )
    assert res.status_code == 502
    assert len(list(tmp_path.glob("*.wav"))) == 1


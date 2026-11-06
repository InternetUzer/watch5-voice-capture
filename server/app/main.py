"""Authenticated audio intake with optional private Yandex Disk archival."""
from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse

from .yandex_disk import YandexDiskError, upload_wav

app = FastAPI(title="Watch5 Voice Capture Ingest", version="0.2.0")
MAX_BYTES = 8 * 1024 * 1024
FILENAME = re.compile(r"^capture_[0-9]{10,16}\.wav$")


def storage_dir() -> Path:
    path = Path(os.environ.get("WATCH_STORAGE_DIR", "./recordings")).resolve()
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/v1/recordings", status_code=status.HTTP_201_CREATED)
async def ingest(request: Request, filename: str, x_device_key: str | None = Header(default=None)) -> JSONResponse:
    expected = os.environ.get("WATCH_API_KEY", "")
    if not expected or not x_device_key or not secrets.compare_digest(expected, x_device_key):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not FILENAME.fullmatch(filename):
        raise HTTPException(status_code=400, detail="Invalid filename")
    if request.headers.get("content-type", "").split(";")[0].strip() != "audio/wav":
        raise HTTPException(status_code=415, detail="Expected audio/wav")
    declared = request.headers.get("content-length")
    if declared:
        try:
            if int(declared) > MAX_BYTES:
                raise HTTPException(status_code=413, detail="Too large")
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid Content-Length")

    target = storage_dir()
    sha = hashlib.sha256()
    written = 0
    fd, tmp_name = tempfile.mkstemp(prefix=".upload-", dir=target)
    try:
        with os.fdopen(fd, "wb") as handle:
            async for chunk in request.stream():
                written += len(chunk)
                if written > MAX_BYTES:
                    raise HTTPException(status_code=413, detail="Too large")
                sha.update(chunk)
                handle.write(chunk)
        with open(tmp_name, "rb") as handle:
            header = handle.read(12)
            if len(header) < 12 or header[:4] != b"RIFF" or header[8:12] != b"WAVE":
                raise HTTPException(status_code=422, detail="Invalid WAV header")

        digest = sha.hexdigest()
        # A repeated watch upload gets the same ID and remote file name.
        uid = hashlib.sha256(f"{filename}:{digest}".encode()).hexdigest()[:24]
        path = target / f"{uid}.wav"
        os.replace(tmp_name, path)
        path.chmod(0o600)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)

    cloud_path = None
    token = os.environ.get("YANDEX_DISK_TOKEN", "")
    if token:
        folder = os.environ.get("YANDEX_DISK_FOLDER", "disk:/Watch5-Voice-Capture")
        remote_name = f"{filename[:-4]}_{digest[:12]}.wav"
        try:
            cloud_path = await upload_wav(path, remote_name, token, folder)
        except YandexDiskError:
            # Keep the local copy and signal failure, so the watch can retry.
            raise HTTPException(
                status_code=502,
                detail="Yandex Disk upload failed; audio retained locally for retry",
            )

    metadata = {
        "id": uid, "filename": filename, "bytes": written, "sha256": digest,
        "received_at": datetime.now(timezone.utc).isoformat(),
        "cloud_synced": cloud_path is not None, "cloud_path": cloud_path,
    }
    (target / f"{uid}.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return JSONResponse(status_code=201, content=metadata)

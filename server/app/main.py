"""Authenticated audio ingestion endpoint; no transcription service."""
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

app = FastAPI(title="Watch5 Voice Capture Ingest", version="0.1.0")
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
    if declared and int(declared) > MAX_BYTES:
        raise HTTPException(status_code=413, detail="Too large")
    target = storage_dir()
    uid = secrets.token_hex(12)
    path = target / f"{uid}.wav"
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
        os.replace(tmp_name, path)
        path.chmod(0o600)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
    metadata = {
        "id": uid, "filename": filename, "bytes": written,
        "sha256": sha.hexdigest(), "received_at": datetime.now(timezone.utc).isoformat()
    }
    (target / f"{uid}.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    return JSONResponse(status_code=201, content=metadata)

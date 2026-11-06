"""WSGI/Passenger adapter for a separately hosted Watch5 recording service.

Does not modify the metalcarcase.ru production Flask application.
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, request
from werkzeug.exceptions import RequestEntityTooLarge

from .yandex_disk import YandexDiskError, upload_wav

MAX_BYTES = 8 * 1024 * 1024
FILENAME = re.compile(r"^capture_[0-9]{10,16}\.wav$")

application = Flask(__name__, static_folder=None)
application.config["MAX_CONTENT_LENGTH"] = MAX_BYTES


def recordings_dir() -> Path:
    configured = os.environ.get("WATCH_STORAGE_DIR", "")
    if not configured:
        raise RuntimeError("WATCH_STORAGE_DIR must be set to an absolute private path")
    path = Path(configured).expanduser().resolve()
    if not path.is_absolute():
        raise RuntimeError("WATCH_STORAGE_DIR must be absolute")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


@application.errorhandler(RequestEntityTooLarge)
def handle_large(_error):
    return jsonify(error="File exceeds 8 MiB"), 413


@application.get("/health")
def health():
    return jsonify(status="ok")


@application.post("/v1/recordings")
def ingest():
    expected = os.environ.get("WATCH_API_KEY", "")
    provided = request.headers.get("X-Device-Key", "")
    if not expected or not provided or not hmac.compare_digest(expected, provided):
        return jsonify(error="Unauthorized"), 401

    filename = request.args.get("filename", "")
    if not FILENAME.fullmatch(filename):
        return jsonify(error="Invalid filename"), 400
    if request.mimetype != "audio/wav":
        return jsonify(error="Expected audio/wav"), 415

    directory = recordings_dir()
    fd, temporary = tempfile.mkstemp(prefix=".watch5-", dir=directory)
    written = 0
    digest = hashlib.sha256()
    try:
        with os.fdopen(fd, "wb") as out:
            while True:
                chunk = request.stream.read(65536)
                if not chunk:
                    break
                written += len(chunk)
                if written > MAX_BYTES:
                    return jsonify(error="File exceeds 8 MiB"), 413
                out.write(chunk)
                digest.update(chunk)

        with open(temporary, "rb") as stored:
            prefix = stored.read(12)
        if len(prefix) < 12 or prefix[:4] != b"RIFF" or prefix[8:12] != b"WAVE":
            return jsonify(error="Invalid WAV header"), 422

        hexhash = digest.hexdigest()
        item_id = hashlib.sha256(f"{filename}:{hexhash}".encode()).hexdigest()[:24]
        local_path = directory / f"{item_id}.wav"
        os.replace(temporary, local_path)
        local_path.chmod(0o600)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

    token = os.environ.get("YANDEX_DISK_TOKEN", "")
    if not token:
        return jsonify(error="Yandex Disk token not configured; file retained locally"), 503

    disk_folder = os.environ.get("YANDEX_DISK_FOLDER", "disk:/Watch5-Voice-Capture")
    remote_filename = f"{filename[:-4]}_{hexhash[:12]}.wav"
    try:
        remote_path = asyncio.run(upload_wav(local_path, remote_filename, token, disk_folder))
    except YandexDiskError:
        return jsonify(error="Yandex Disk upload failed; file retained locally"), 502

    metadata = {
        "id": item_id,
        "filename": filename,
        "sha256": hexhash,
        "bytes": written,
        "received_at": datetime.now(timezone.utc).isoformat(),
        "cloud_synced": True,
        "cloud_path": remote_path,
    }
    (directory / f"{item_id}.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return jsonify(metadata), 201

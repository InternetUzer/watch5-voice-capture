"""Upload a synthetic 1-second silent WAV to test HTTPS -> server -> Yandex Disk.

Usage: WATCH_API_KEY=... python smoke_upload.py https://voice.metalcarcase.ru/v1/recordings
No real conversation audio or OAuth token is sent from the test client.
"""
from __future__ import annotations

import io
import hashlib
import struct
import argparse
from datetime import datetime, timezone
from pathlib import Path
from dotenv import load_dotenv
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import wave


def make_wav(seconds: int = 1) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(bytes(32000 * seconds))
    now = int(time.time() * 1000)
    timeline = {"version": 1, "started_at": datetime.fromtimestamp(now / 1000, timezone.utc).isoformat(),
                "timezone_offset_minutes": 0, "recovered": False, "segments": [
                    {"audio_start_ms": 0, "audio_end_ms": seconds * 1000,
                     "started_at_ms": now, "ended_at_ms": now + seconds * 1000, "source": "unknown"}]}
    meta = json.dumps(timeline).encode()
    data = bytearray(output.getvalue() + b"vcap" + struct.pack("<I", len(meta)) + meta + bytes(len(meta) % 2))
    struct.pack_into("<I", data, 4, len(data) - 8)
    return bytes(data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("endpoint")
    parser.add_argument("--seconds", type=int, choices=range(1, 601), default=1)
    args = parser.parse_args()
    address = args.endpoint.strip()
    if not address.startswith("https://"):
        print("An HTTPS endpoint is required", file=sys.stderr)
        return 2
    load_dotenv(Path.home() / ".watch5-voice-capture.env", override=False)
    key = os.environ.get("WATCH_API_KEY")
    if not key:
        print("WATCH_API_KEY is missing from environment", file=sys.stderr)
        return 2
    name = f"capture_{int(time.time() * 1000)}.wav"
    url = address + "?filename=" + urllib.parse.quote(name)
    data = make_wav(args.seconds)
    request = urllib.request.Request(
        url, data=data, method="POST",
        headers={"Content-Type": "audio/wav", "X-Device-Key": key},
    )
    try:
        with urllib.request.urlopen(request, timeout=240) as response:
            payload = json.load(response)
            print(json.dumps({
                "status": response.status,
                "cloud_synced": payload.get("cloud_synced"),
                "cloud_verified": payload.get("cloud_verified"),
                "cloud_path": payload.get("cloud_path"),
                "bytes": payload.get("bytes"),
            }, ensure_ascii=False, indent=2))
            return 0 if (response.status == 201 and payload.get("cloud_synced") is True
                         and payload.get("cloud_verified") is True and payload.get("filename") == name
                         and payload.get("bytes") == len(data)
                         and payload.get("sha256") == hashlib.sha256(data).hexdigest()) else 1
    except urllib.error.HTTPError as err:
        print(f"Server returned HTTP {err.code}", file=sys.stderr)
        return 1
    except urllib.error.URLError as err:
        print(f"Network/TLS error: {err.reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())


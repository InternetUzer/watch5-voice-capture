"""Upload a synthetic 1-second silent WAV to test HTTPS -> server -> Yandex Disk.

Usage: WATCH_API_KEY=... python smoke_upload.py https://voice.metalcarcase.ru/v1/recordings
No real conversation audio or OAuth token is sent from the test client.
"""
from __future__ import annotations

import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import wave


def make_wav() -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(bytes(32000))
    return output.getvalue()


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python smoke_upload.py https://voice.metalcarcase.ru/v1/recordings", file=sys.stderr)
        return 2
    address = sys.argv[1].strip()
    if not address.startswith("https://"):
        print("An HTTPS endpoint is required", file=sys.stderr)
        return 2
    key = os.environ.get("WATCH_API_KEY")
    if not key:
        print("WATCH_API_KEY is missing from environment", file=sys.stderr)
        return 2
    name = f"capture_{int(time.time() * 1000)}.wav"
    url = address + "?filename=" + urllib.parse.quote(name)
    request = urllib.request.Request(
        url, data=make_wav(), method="POST",
        headers={"Content-Type": "audio/wav", "X-Device-Key": key},
    )
    try:
        with urllib.request.urlopen(request, timeout=35) as response:
            payload = json.load(response)
            print(json.dumps({
                "status": response.status,
                "cloud_synced": payload.get("cloud_synced"),
                "cloud_path": payload.get("cloud_path"),
                "bytes": payload.get("bytes"),
            }, ensure_ascii=False, indent=2))
            return 0 if response.status == 201 and payload.get("cloud_synced") is True else 1
    except urllib.error.HTTPError as err:
        print(f"Server returned HTTP {err.code}", file=sys.stderr)
        return 1
    except urllib.error.URLError as err:
        print(f"Network/TLS error: {err.reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

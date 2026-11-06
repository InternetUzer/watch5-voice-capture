# Watch5 Voice Capture

HarmonyOS / ArkTS audio-capture prototype for Huawei Watch 5 with a self-hosted FastAPI server and **optional private Yandex Disk archival**.

## Project

- `watch/` — sound-level triggering, local WAV clips, pre-roll, user-initiated HTTP upload.
- `server/` — API-key-protected audio ingestion and Yandex Disk REST API upload.
- `server/tests/` — server tests, including a mocked Yandex Disk adapter.
- `docs/INSTALL_RU.md` — watch installation instructions.
- `docs/YANDEX_DISK_RU.md` — [Yandex Disk setup for Windows](docs/YANDEX_DISK_RU.md).
- `docs/PROTOCOL.md` — recording upload protocol.

## Status (November 2026)

- **DevEco Studio 6.1.1.280:** a user reported a successful ArkTS/HAP build on Windows; signing was not configured. Actual installation and operation on Watch 5 remain **untested**.
- **Yandex Disk feature:** code added, but live OAuth upload **not tested** against a real account. Server unit tests use a mocked HTTP client.
- Watch uploads require tapping the upload button. Automatic background upload is **not implemented**.
- The recorder is sound-energy based, not true speech-specific VAD. The recording session is started by the wearer and the OS mic indicator is not bypassed.
- The server has no automatic transcription stage and this chat has no private Yandex Disk access.

## Server on Windows (PowerShell)

```powershell
cd C:\Users\Serega\DevecostudioProjects\watch5-voice-capture\server
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt

$env:WATCH_API_KEY = [guid]::NewGuid().ToString("N")
$yandexSecret = Read-Host 'Yandex OAuth token' -AsSecureString
$env:YANDEX_DISK_TOKEN = [System.Net.NetworkCredential]::new('', $yandexSecret).Password
$env:YANDEX_DISK_FOLDER = 'disk:/Watch5-Voice-Capture'
$env:WATCH_STORAGE_DIR = "$PWD\recordings"

.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

If `YANDEX_DISK_TOKEN` is absent, uploads are **local-only**. A private Yandex Disk folder is created by the API when configured. Do not commit OAuth tokens, publish the `.env` file, or expose the local HTTP endpoint directly to the Internet. Provide a reachable HTTPS endpoint for the watch, with valid TLS and a strong device key.

See [Yandex Disk integration guide](docs/YANDEX_DISK_RU.md).

## Tests

```bash
cd server
python -m pip install -r requirements.txt
python -m pytest -q
```

## Limitations

An archive file must be no larger than **8 MiB** for the current watch uploader. Cloud upload failures return HTTP 502 and retain the local WAV for retry. Public download links are **not** created. This chat cannot automatically read your private Yandex Disk; attach an audio file or provide an accessible share link when asking for a transcript.

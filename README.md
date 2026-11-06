# Watch5 Voice Capture

Prototype application for **Huawei Watch 5 / HarmonyOS**, with self-hosted audio-upload server.

## Contents

- `watch/` — ArkTS wearable app: microphone capture, energy-based sound trigger, 3-second pre-roll, WAV recording, user-controlled upload.
- `server/` — Python FastAPI audio ingestion endpoint with API-key authentication.
- `server/tests/` — API tests.
- `docs/INSTALL_RU.md` — installation and testing instructions in Russian.
- `docs/PROTOCOL.md` — upload API contract.

## Status

**Unverified prototype.** Source files have been committed; HAP compilation and on-device testing have not been performed. Watch 5 SDK compatibility, background capture, microphone sampling format, battery use and audio-file integrity need hardware validation.

Recordings are initiated by the user starting a monitoring session; the operating system's active-microphone indication is not bypassed. The app does not silently restart after reboot.

The detector is **sound-level based**, not speech-specific VAD. Uploads are manually initiated. Audio is not transcribed on the watch.

## Build

1. Open `watch/` in a compatible Huawei DevEco Studio installation.
2. Select the SDK for the watch's HarmonyOS firmware; address any API or build errors.
3. Configure a developer signing certificate and build a signed HAP.
4. Enable wireless debugging on the watch and use:

```bash
hdc tconn IP:PORT
hdc list targets
hdc install PATH_TO_SIGNED_HAP
```

See [Russian installation guide](docs/INSTALL_RU.md).

## Server

```bash
cd server
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export WATCH_API_KEY='choose-a-long-secret'
export WATCH_STORAGE_DIR='./recordings'
uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Use HTTPS with a valid certificate before connecting the watch.

## Caution

No HAP release or verified watch installation is available yet. No claims of production readiness.

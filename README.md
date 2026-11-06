# Watch5 Voice Capture v2

Recording candidate for Huawei Watch 5 (target HarmonyOS 6.1.0/API 23) with a separate
Python HTTPS service and the Android **Прораб+** companion in `InternetUzer/TECHNADZOR`.

- START arms speech-oriented recording: 2-second pre-roll, 5 seconds after speech,
  then pause in the same file. 600 seconds of accumulated PCM produces one WAV.
- Continuous mode records until STOP. STOP finalizes the short remainder.
- Bluetooth headset capture runs on the Android companion; no manufacturer filter.
  Live listening on the watch is optional and independent of archival recording.
- Durable local outboxes; automatic retry; removal only after matching cloud size and
  SHA-256 proof. The phone can relay completed watch files and returns a persisted cloud
  receipt. Interrupted `.part` files are recovered on the next recording-app start.
- Embedded WAV `vcap` timeline plus a verified JSON sidecar map playback time to original
  timestamps. New cloud filenames show the first captured timestamp in UTC.
- Device API keys use HarmonyOS Asset Store / AndroidKeyStore. Yandex OAuth stays server-side.

## Status

This branch contains **v2 implementation and automated tests**, not a hardware-validated
release. The v2 HAP has not been compiled or signed in this environment. The older HAP
build report does not validate these new APIs. Wear Engine registration, matching signing
certificates and real-device tests are still required. See [v2 acceptance and setup](docs/V2_RU.md).
Do not merge/deploy this as a proven watch release before those checks.

The speech detector is a voice-band energy heuristic, not a trained VAD. Machinery and
music can trigger it. Background recording uses normal system permissions and indicators.
Auto-starting the microphone after reboot is not implemented: restore the queue, then
request an explicit START. OS-controlled upload scheduling can be delayed.

## Tests

```sh
python -m pip install -r server/requirements.txt
PYTHONPATH=server python -m pytest -q server/tests
node --test watch/tests/*.test.mjs  # Node 24+
```

Node tests exercise pure capture, WAV recovery and messaging code with API shims; they
are not an ArkTS compiler or watch hardware test. Server cloud tests use a mock Disk API.
The companion has Kotlin and Robolectric tests in its own repository.

## Server

Use the existing isolated `voice.metalcarcase.ru` Passenger service, or run
`uvicorn app.main:app --host 127.0.0.1 --port 8000` from `server/` behind HTTPS.
Configure `WATCH_API_KEY`, `YANDEX_DISK_TOKEN`, `YANDEX_DISK_FOLDER` and a private
`WATCH_STORAGE_DIR` through protected server configuration. Never commit these values.

The server accepts PCM16/16 kHz/mono WAV up to **24 MiB**, at most 600 seconds of PCM.
No cloud verification means no permission to delete the original. WAV and JSON sidecar
must both be verified. Retries use deterministic paths and overwrite the same content.
Main-site DNS, code and mail are outside this service's deployment scope.

- [Protocol](docs/PROTOCOL.md)
- [Watch installation](docs/INSTALL_RU.md)
- [REG.RU deployment](docs/METALCARCASE_DEPLOY_RU.md)
- [Yandex OAuth setup](docs/YANDEX_DISK_RU.md)

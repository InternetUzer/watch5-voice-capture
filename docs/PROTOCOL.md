# Upload protocol

`POST /v1/recordings?filename=capture_1700000000000.wav`

Headers: `X-Device-Key: <secret>`, `Content-Type: audio/wav`.
Body: raw WAV, maximum 8 MiB.

Response: HTTP 201 with JSON `{"id":"...","filename":"...","sha256":"...","bytes":123,"received_at":"..."}`.

Uploads are manually initiated; retries are not idempotent in v0.1. Files are not auto-deleted on the watch. AI processing is downstream and not included.

# Voice Capture v2 protocol

## HTTPS ingestion

`POST /v1/recordings?filename=capture_<epoch-ms>.wav`
Headers: `X-Device-Key: <device secret>`, `Content-Type: audio/wav`.
Raw PCM16 mono 16 kHz RIFF WAV; max 24 MiB including metadata; PCM <=19,200,000 bytes.

HTTP 201 JSON contains `id`, `filename`, `bytes`, `sha256`, `received_at`,
`cloud_synced`, `cloud_verified`, `cloud_path`. Local deletion requires both booleans
**true**, original filename, exact byte length and SHA-256, and a `disk:/` path.
HTTP success by itself, or an old v1 `cloud_synced` field, is insufficient.
The server verifies Disk resource type, size and SHA-256 after each PUT (including 202).
It also verifies the timeline sidecar before acknowledging. Failures preserve originals.
Retries of filename+hash have a deterministic server ID and cloud filename.

## Timing

Optional RIFF `vcap` chunk: UTF-8 JSON, even-byte RIFF padding. Version 1 fields:
`started_at` (ISO), `timezone_offset_minutes` (east positive), `recovered` (boolean),
`segments` array. Each segment stores `audio_start_ms`, `audio_end_ms`,
`started_at_ms`, `ended_at_ms`, `source` (`watch`, `headset`, `unknown`).
The two intervals have equal duration. Segments are contiguous in captured audio but
can be separated by arbitrary real-world silence. Recovered files may have incomplete
last-journal timing and are explicitly marked. Times come from each source device clock;
they are not guaranteed NTP-synchronized. Cloud WAV filenames prefix the first known
segment timestamp in UTC, with `.timeline.json` next to the WAV.

## Wear Engine authenticated peers

Register exact bundle/package names and public certificate fingerprints. Binary live
frames: ASCII `WV2A`, uint32 LE session, uint32 LE sequence, float64 LE epoch-ms timestamp,
uint32 LE payload size, followed by 2..3200 even bytes of PCM16/16kHz/mono (24-byte header).
Only current-session increasing-sequence frames are played. The bounded live queue may
drop packets to limit latency; canonical recording always happens before live transport.

JSON control: `{type:"control",session,id,mode,sensitivity,listening,stop}`.
Modes `auto|continuous|listen`, sensitivity `low|normal|high`. Every command describes
full desired state, has a monotonic ID, and is acknowledged through matching-session
status with `id >= command.id`. STOP finalizes audio and closes the phone helper.
Unconfirmed STOP is shown explicitly and retransmitted while the watch process lives.
An unreachable phone cannot be stopped instantaneously; its notification has local STOP.

JSON status: `type:"status"`, session/id, source_available, stopped, mode/listening,
elapsed_ms, queue, upload, source. Status expires after 4 s. A stale link is distinct
from a fresh status reporting the headset microphone unavailable.

File relay: authenticated `relay_query` carries filename, bytes, sha256. `relay` response
returns `need_file`, `accepted`, and optionally the verified server `receipt`. If needed,
Wear Engine transfers the finalized WAV; Android checks its hash and atomically saves
it. Receiving a phone copy never authorizes watch deletion. WorkManager sends the copy
to the server, saves the exact receipt durably, then removes its copy. The watch retrieves
and independently validates that receipt before removing its own original. Relay is
paused while live listening is enabled. Small receipt JSON records remain for reconnects.

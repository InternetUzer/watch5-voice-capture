# Watch5 Voice Capture

Prototype for a user-started, visibly active sound-triggered recording session on Huawei Watch 5, plus optional self-hosted FastAPI audio-ingest server.

**Status:** Sources only. The HarmonyOS HAP has not been compiled or tested on a physical Watch 5.

## Features
- AudioCapturer PCM capture with sound-level triggering and pre-roll.
- WAV clips saved locally in the watch application sandbox.
- Upload of selected audio files to a user-owned HTTPS endpoint.
- Optional FastAPI ingestion API.
- No on-watch speech transcription; integrate an AI pipeline downstream.

## Get the complete sources

The complete source archive was prepared separately in this conversation. To publish it, use the Git bundle included with the archive:

```bash
git clone watch5-voice-capture.bundle watch5-voice-capture
cd watch5-voice-capture
git remote add origin https://github.com/InternetUzer/watch5-voice-capture.git
git push origin main
```

If the repository has been initialized with this README first, use a new branch for the imported source history or integrate the histories before pushing. Do **not** force-push without reviewing.

## Build and installation

Use DevEco Studio with a compatible Huawei HarmonyOS SDK, enable developer mode and wireless debugging on the watch, build a signed HAP, then install via `hdc install <signed-hap-path>`. Device-specific SDK compatibility and background-recording behavior require hardware verification.

## Scope and limitations

Monitoring is started explicitly in the app. The OS microphone indicator remains visible. Automatic background-start without user interaction, hidden monitoring and boot persistence are not supported.


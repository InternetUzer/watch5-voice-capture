# Vendored WebRTC VAD

Source: https://github.com/wiseman/py-webrtcvad
Pinned commit: `e283ca41df3a84b0e87fb1f5cb9b21580a286b09`.
The `webrtc/` directory is copied unchanged from `cbits/webrtc/`.
No Python interpreter or Python wrapper is included in the app.
`SHA256SUMS.json` records the unmodified upstream source hashes.
License: WebRTC BSD-3-Clause; see LICENSE.webrtc for the complete upstream notice.
The same notice is bundled in the HAP as rawfile/webrtc-license.txt.

Only the C VAD/signal-processing sources and checks.cc are compiled;
SIMD-specific third-party objects are not needed by this portable build.

# Architecture

The AppKit app owns settings, global hotkeys, microphone capture, transcript display,
and clipboard/file output. `Core.swift` contains testable capture gating and modifier
key decoding. `Recorder.swift` converts audio to 16 kHz mono float32.

`WorkerProcess.swift` starts a private Python service over inherited pipes.
`app_worker.py` supervises an isolated MLX process. The supervisor terminates and
reaps it when the app stops, quits, or disappears, escalating if inference hangs.
Model loading and every transcription run on the engine’s main thread.

Requests contain an identifier and bounded base64 audio. Responses match that
identifier. The app rejects stale callbacks, snapshots output settings for each
recording, and retains pending audio in memory for retries. Stop or quit discards
that audio. Native watchdogs cover model loading and transcription timeouts.

New notes use exclusive creation and unique filenames. Append mode preserves the
existing file. A save failure leaves the transcript available in the interface.
Audio and transcript content are not diagnostically logged.

Settings live in `~/Library/Application Support/ZK Dictate/settings.json`.
The source installer builds `~/Applications/ZK Dictate.app`, which uses the source
folder’s Python environment. A portable, notarized distribution is future work.

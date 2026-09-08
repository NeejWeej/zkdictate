# Architecture

The AppKit app owns settings, global hotkeys, microphone capture, transcript display,
and clipboard/file output. `Core.swift` contains testable capture gating and modifier
key decoding. `Recorder.swift` converts audio to 16 kHz mono float32.

`WorkerProcess.swift` starts a private Python service over inherited pipes.
`app_worker.py` supervises an isolated MLX process. The supervisor terminates and
reaps it when the app stops, quits, or disappears, escalating if inference hangs.
Model loading and every transcription run on the engine’s main thread.
The persisted model choice is passed explicitly to the supervisor and engine.
Cached models are resolved offline first. For newer model exports, a temporary
symlink view adapts the weights filename expected by mlx-whisper 0.4.x without
modifying the Hugging Face cache or copying the weights.

Requests contain an identifier and bounded base64 audio. Responses match that
identifier. The app rejects stale callbacks, snapshots output settings for each
recording, and retains pending audio in memory for retries. Stop or quit discards
that audio. Native watchdogs cover model loading and transcription timeouts.

New notes use exclusive creation and unique filenames. Append mode preserves the
existing file. A save failure leaves the transcript available in the interface.
Audio and transcript content are not diagnostically logged.

`Clipboard.swift` isolates full-format clipboard access and opt-in backup state.
External data providers are read off the main thread with a deadline; stale or
cancelled completions cannot write. Restores require the last owned change count
and a matching content fingerprint. Clipboard replacement is not atomic on macOS.
Backups have independent lifetimes, bounded retained data, privacy-marker checks,
and no disk persistence. `ClipboardPanel.swift` provides the embedded clipboard pane and hidden-by-default previews;
expiry and lifecycle cleanup release preview text and thumbnails as well as data.
Native tests exercise the state machine and a separate named pasteboard, never the
user's general clipboard.

Settings live in `~/Library/Application Support/ZK Dictate/settings.json`.
The source installer builds `~/Applications/ZK Dictate.app`, which uses the source
folder’s Python environment. A portable, notarized distribution is future work.

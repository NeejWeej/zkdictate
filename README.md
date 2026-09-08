# ZK Dictate

**Local voice dictation for your Mac. No internet required after setup and the
initial model download.**

Hold a key, speak, and release. ZK Dictate turns your speech into text, then copies
it to your clipboard, saves a Markdown note, or appends it to a file. Audio is
processed on your Mac, never sent to a transcription service.

**Requires an Apple Silicon Mac running macOS 14 or newer.**

## How it works

- The first time you start dictation, the app downloads the **8-bit Whisper large-v3-turbo**
  speech recognition model by default. Setup and this initial download require internet.
- The model stays cached on your Mac and runs locally using **MLX** on Apple Silicon.
  Once it’s downloaded, you can dictate offline.
- Hold your chosen hotkey to record, then release it to transcribe. Recordings stay
  in memory rather than being saved as audio files; text goes to your chosen output.

## Setup

1. Download this repository using **Code → Download ZIP**, then unzip it into a folder you’ll keep.
2. Double-click **Install.command**. It installs the required tools, builds the app, and opens it. If Apple’s developer tools need installing, finish that prompt and run the installer again.
3. Allow **Microphone** and **Input Monitoring** for **ZK Dictate**. Restart the app if macOS asks.

You’ll find the app in `~/Applications/ZK Dictate.app`. Keep the downloaded folder
in place—the app uses its Python environment.

You can also run `bash install.sh` from the downloaded folder.

## Dictate

1. Keep the default **Whisper Turbo (8-bit, Default)** model, or choose **Whisper Turbo**. Each model downloads on first use.
2. Choose **Copy to clipboard**, **Save a new note**, or **Append to file**.
3. Click **Start Dictation** and wait until it’s ready.
4. Hold **Right Command** (or your chosen dictation key) for at least 1.5 seconds
   while speaking, then release.

To change the hotkey, stop dictation, click **Record Key…**, and press a single
Command, Option, Control, Shift, or F1–F20 key. Escape cancels; letters and Space are rejected.
You can also change the notes folder in the app. **Pause** temporarily disables
recording; **Stop Dictation** turns off recording and unloads the model. Closing the app stops everything.
The latest transcript stays visible for copying or saving again.

Want to recover what was on the clipboard? Select the **Clipboard** tab and enable
**Keep clipboard backups**. Restore the previous entry or what you copied before
dictating, with optional previews and automatic expiry. Backups are off by default.
Turn on **Side by side** to keep clipboard controls beside your dictation settings;
the app remembers this layout.

Notes default to `~/Documents/ZK Dictate`. You can choose any folder, including
an Obsidian vault. Existing notes aren’t moved or overwritten.

Browse the [wiki](https://github.com/NeejWeej/zkdictate/wiki) for setup and usage,
or read the complete [feature guide](docs/features.md).

## Troubleshooting

- **Hotkey permission looks enabled but doesn’t work after an update:** remove ZK Dictate
  from Input Monitoring, add `~/Applications/ZK Dictate.app` again, and restart it.
- **A recording is discarded:** hold the dictation key for at least 1.5 seconds
  without pressing other keys.
- **Transcription fails:** click **Retry Transcription**. Pending audio is kept in
  memory for retry; recordings aren’t saved to disk.

## Development

```sh
make test          # Python and installer tests
make test-native   # Hotkey, settings, and note-output tests
make app           # Build the Mac app
```

GitHub Actions runs the tests and builds the app on pushes and pull requests.
See [architecture](docs/architecture.md) and [release checks](docs/release-checklist.md)
for implementation details and the remaining checks before a packaged release.

Developed with Codex.

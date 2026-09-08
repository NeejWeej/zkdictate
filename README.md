# ZK Dictate

Hold a key, speak, and release. ZK Dictate transcribes on your Mac and copies the
text, saves a Markdown note, or appends it to a file.

**Requires an Apple Silicon Mac running macOS 14 or newer.**

## Setup

1. Download this repository using **Code → Download ZIP**, then unzip it into a folder you’ll keep.
2. Double-click **Install.command**. It installs the required tools, builds the app, and opens it. If Apple’s developer tools need installing, finish that prompt and run the installer again.
3. Allow **Microphone** and **Input Monitoring** for **ZK Dictate**. Restart the app if macOS asks.

You’ll find the app in `~/Applications/ZK Dictate.app`. Keep the downloaded folder
in place—the app uses its Python environment. The first run downloads the speech
model; after that, transcription can work offline.

You can also run `bash install.sh` from the downloaded folder.

## Dictate

1. Choose **Clipboard**, **New note**, or **Append to file**.
2. Click **Start Dictation** and wait until it’s ready.
3. Hold **Right Command** while speaking for at least 1.5 seconds, then release.

Change the hotkey or notes folder in the app. **Pause** temporarily disables
recording; **Stop Dictation** unloads the worker. Closing the app stops everything.
The latest transcript stays visible for copying or saving again.

Notes default to `~/Documents/ZK Dictate`. You can choose any folder, including
an Obsidian vault. Existing notes aren’t moved or overwritten.

## Troubleshooting

- **Permissions look enabled but don’t work after an update:** remove ZK Dictate
  from Input Monitoring, add `~/Applications/ZK Dictate.app` again, and restart it.
- **A recording is discarded:** hold the dictation key for at least 1.5 seconds
  without pressing other keys.
- **Transcription fails:** click **Retry**. Pending audio stays in memory until
  you stop or quit; recordings aren’t saved to disk.

## Development

```sh
make test          # Python and installer tests
make test-native   # Hotkey, settings, and note-output tests
make app           # Build the Mac app
```

GitHub Actions runs the tests and builds the app on pushes and pull requests.
See [architecture](docs/architecture.md) and [release checks](docs/release-checklist.md)
for implementation details and the remaining checks before a packaged release.

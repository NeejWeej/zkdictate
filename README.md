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
You can also change the notes folder in the app. **Stop Dictation** turns off
recording and unloads the model. **Start Dictation** loads it again. Closing the app stops everything.
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

### Experimental finish and paste

Stop dictation, then enable **Finish and paste with ⌘V (experimental)** and start
again. This setting (`finish_and_paste`) defaults to off. macOS Accessibility
access is required when enabled; the normal mode still uses a listen-only tap.

In **Copy to clipboard** mode, press V while holding Right Command to finish the
recording and paste when ready. You can also press ⌘V during transcription.
Quick ⌘V presses still paste normally: interception starts only after 1.5 seconds
of clean recording. A recording cancelled by another key never intercepts paste.
Repeated shortcut presses queue one paste. Releasing Command does not cancel it;
other key presses (including Escape) cancel the queued paste while transcription
continues to the clipboard. Stop, sleep, failure, or an empty result also clear it.
The paste goes to the cursor at completion, without tracking apps or focus, and
never sends Enter. Note/file output modes keep their normal behavior.

To revert the experiment, stop dictation, uncheck the setting, and start again.

### Readability and dictation status

Use **⌘+** (or **⌘=**) and **⌘−** to resize text throughout both panes, and
**⌘0** to reset. The window also has zoom buttons. Zoom (80–150%) persists.
These shortcuts apply only inside ZK Dictate.

The large status banner and Start/Stop controls remain above both panes when
scrolling. It distinguishes stopped, loading, ready, recording (mic on),
and transcribing (mic off), and explicitly marks a queued automatic paste.
Side-by-side panes share added window width; the latest transcript appears first.

Controls are grouped into spaced sections: **Your words**, **How you record**,
**Where your words go**, and **Setup & permissions**. Setup and **Backup settings**
expand on click; both clipboard restore choices remain visible in their own cards.
Folder/file controls appear only for the selected output mode.

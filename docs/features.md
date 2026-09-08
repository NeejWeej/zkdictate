# Features and behavior

ZK Dictate is a local, hold-to-talk dictation app for Apple Silicon Macs running
macOS 14 or newer. It converts speech into text for the clipboard or Markdown
files. It does not type directly into the focused application.

## Start dictation

Allow Microphone and Input Monitoring for ZK Dictate, choose an output, and click
**Start Dictation**. Input Monitoring lets the hotkey work while another app is
focused. Microphone access is used only during a recording.

Wait for **Ready**, then hold your dictation key to speak. Starting dictation
loads the model but leaves the microphone off until you hold the key.

If you press the key while the model is loading or transcribing, nothing is
recorded. Release it and press it again after **Ready** appears.

## Models and offline use

The **Model** menu offers:

| Model | Weight download | Behavior |
| --- | --- | --- |
| Whisper Turbo | About 1.61 GB | Standard model with 16-bit floating-point weights. |
| Whisper Turbo (8-bit, Default) | About 864 MB | Quantized version of the same model, with smaller weights. Speed and accuracy may differ. |

The default is **Whisper Turbo (8-bit, Default)**. The app remembers the model you
choose. To switch models, click **Stop Dictation**, choose a model, and start again.

If a failed transcription is waiting for retry, stopping discards that recording.
Retry it before switching models if you want to keep it.

Each model downloads from Hugging Face the first time you use it. The app uses
specific, tested model versions and keeps the downloaded files on your Mac.
Afterward, it loads them without an internet connection. Deleting those files
means downloading the model again.

Models run on your Mac using MLX. Audio is never sent to a transcription service.
Setup and the first download of each model require internet.

If a model takes more than 10 minutes to download or load, the app stops trying
and offers **Retry**. If transcription takes more than 2 minutes, it stops and
offers **Retry Transcription** for the same recording.

## Choose your dictation key

The default key is **Right Command**. To change it:

1. Stop dictation, then click **Record Key…**.
2. Press one key: Command, Option, Control, Shift, or F1–F20. Left and right
   modifier keys are separate choices.
3. The app saves the key and shows its name. Start dictation again when ready.

Press **Escape**, click **Cancel**, or switch to another app to cancel without
changing your key.

Letters, numbers, Space, punctuation, arrow/navigation keys, Caps Lock, and
Fn/Globe by itself cannot be used. If you press one, the app keeps waiting for a
supported key. It saves the first valid key immediately, so press only the key
you want. Shortcuts with multiple keys are not supported.

The function-key row may control brightness or volume instead of sending an
F-key. Depending on your keyboard settings, you may need to hold Fn to use an
F-key; only the F-key is saved as your choice.

Your dictation key still works normally in other apps. ZK Dictate does not block
system shortcuts or change your keyboard settings.

You can choose a key before granting Input Monitoring. Using it to dictate while
other apps are focused still needs that permission. Choosing a key never starts
recording.

## When a recording is kept or discarded

- **Hold to record; release to transcribe.** There is no toggle-to-record mode.
- **Hold for at least 1.5 seconds.** This measures how long the key is held, not
  how long you spoke. Shorter recordings are discarded without transcription.
- **Release other modifiers before starting.** A dictation key pressed while another
  Command, Option, Control, or Shift key is held does not start recording.
- **Pressing another key means the recording will be discarded.** For example,
  holding Right Command and pressing C will discard the recording. The microphone
  stays on until you release the dictation key; then the audio is thrown away.
  Pressing or releasing another Command, Option, Control, or Shift key also marks
  the recording for discard.
- **Letting go of a letter key is different from pressing it.** If you were already
  holding A before recording started, releasing A does not discard the recording.
  Pressing A after recording starts does. The same applies to other keys that
  are not modifiers.
- **Only one recording or transcription runs at a time.** You cannot start the
  next recording while the previous one is transcribing.
- **Ten minutes is the recording limit.** At that limit, the app stops recording
  and discards the audio. It does not save a partial transcript.
- **Close folder and file pickers before dictating.** The dictation key is ignored
  while one of those dialogs is open.
- **If macOS interrupts keyboard monitoring, the recording is cancelled.** The app
  tries to resume monitoring, but the interrupted recording is discarded.

While recording, the status says **Recording** and the menu-bar label becomes
**● ZK**.

With **Sound cues** enabled, a sound plays when recording starts and when you
release the dictation key. The release sound also plays for discarded recordings;
it does not mean text was saved. Stopping, quitting, or other interruptions may
end a recording without a sound.

If no speech is recognized, the app shows **No speech detected**. Models can make
mistakes, including producing text from silence. Review transcripts, especially
names and unusual terms.

## Where text goes

| Output | Result |
| --- | --- |
| Copy to clipboard | Replaces the clipboard with the transcript. Paste it yourself wherever you want it. |
| Save a new note | Creates a new `.md` file in the chosen notes folder, with a timestamp and unique suffix. Existing notes are not overwritten. |
| Append to file | Adds the transcript and two newlines to the selected file. Creates the file if needed; preserves existing contents. |

Notes default to `~/Documents/ZK Dictate`. **Choose Notes Folder…** accepts any
folder, including an Obsidian vault. It changes where future notes go; it does not
move existing notes. Append mode requires choosing an output file before starting.
When choosing an existing output file, macOS may ask about replacing it. ZK
Dictate uses the selected path to append text; it does not erase that file.

You cannot change the output, sound cues, or destination while recording,
transcribing, or waiting to retry a failed transcription. Retry sends text to
the destination chosen for that recording.

To use **Record Key…**, stop dictation first. If audio is waiting for retry,
stopping discards it.

The latest transcript stays visible in the app:

- **Copy Transcript** copies it again.
- **Save Transcript as Note** creates another note in the current notes folder,
  regardless of the selected automatic output mode. Repeating this creates separate notes.
- **Clear** clears the displayed transcript, not your clipboard or saved files.

Copy, Save, and Clear do nothing while recording or transcribing. If saving fails,
the text stays visible so you can copy it or try saving again.

If a new recording produces no text, the previous transcript remains on screen.
The transcript display has no history and is empty after relaunch. Optional
clipboard backups can temporarily retain earlier copied transcripts. Files you saved and text you copied are separate from this display.

## Clipboard backups

Select the **Clipboard** tab and enable **Keep clipboard backups**
if you want to undo clipboard changes. This is **off by default**. With it disabled,
copying a transcript replaces the clipboard normally and no backup is saved.

Use **Dictation** and **Clipboard** to switch tabs, or turn on **Side by side**
to keep both visible in one window. The layout is remembered across launches.
Each pane scrolls independently when the window is too short for its contents.

When enabled, the app captures the clipboard immediately before copying a
transcript, including when you click **Copy Transcript**. It keeps two choices:

| Button | Restores |
| --- | --- |
| Restore before last copy | What was on the clipboard just before our latest transcript copy. This may be the previous transcript. |
| Restore before dictation | The most recent clipboard content copied outside ZK Dictate. |

For example: copy A elsewhere, dictate twice, copy B elsewhere, then dictate.
Both buttons now restore B. Dictate once more and **before last copy** restores the
previous transcript, while **before dictation** still restores B.

The app recognizes its own copies and restores by tracking clipboard ownership
and contents. It does not decide whether something is a transcript by reading its
words. Copying identical words in another app counts as an external copy.

**Show previews** reveals a short text excerpt, an image thumbnail, or a label for
files and other content. Previews are hidden initially and when the clipboard pane
is hidden. **Hide previews when leaving the app** is on by default; turn it off
to keep previews visible when you switch to another app. This preference is saved.
Expiry, clearing backups, sleep, lock, and quitting still clear previews.
Both previews can show the same content.

### Restore without losing a newer copy

Restore is available only while the clipboard still contains our latest copy or
restore. Copying something elsewhere disables both restore buttons. A new
transcription copy can then back up that newer clipboard content.

Restoring one choice keeps the other, so you can switch between them until they
expire or something else changes the clipboard. Repeatedly copying the same
transcript while it is still on the clipboard does not replace the backups or
restart their timers.

Clipboard checks are best-effort: macOS has no atomic clipboard compare-and-replace
operation. The app checks for changes before writing and refuses stale restores,
but another app can still race with the final system write.

### Expiry and privacy

Choose **1, 5, or 15 minutes**; the default is 5. Each backup expires independently
from its capture time. More dictations and restores do not extend the original
backup's lifetime. Shortening the timeout applies to existing backups immediately.

Expiry removes the backup data and its preview. **Clear backups**, disabling the
feature, quitting, screen sleep, locking the Mac, or leaving your macOS user session
also clear the backups. **Stop Dictation** cancels an unfinished clipboard copy but
keeps existing backups until their normal expiry.

The app holds backups only in memory; it does not write them to files or logs.
Clearing them does not erase the system clipboard, your saved files, or a separate
clipboard manager's history.

Content marked private, temporary, or excluded from clipboard history is not backed
up or overwritten while backups are enabled. These markers are supplied by other
apps; unmarked sensitive text is handled like ordinary text.

### Images, files, and unusual formats

The backup preserves all readable clipboard formats and multiple clipboard items,
not just plain text or the preview. Ordinary images and rich text are supported.
Copied files are references: restoring them does not recreate a file that was
moved or deleted. An empty clipboard can also be restored.

Each backup is limited to **16 MB** of clipboard data. File promises, unavailable
formats, or a read taking more than 3 seconds are refused. The transcript remains
visible and the clipboard is left alone when a backup cannot be captured safely.
You can disable backups and click **Copy Transcript** if you prefer to replace the
clipboard without saving it. Unexpected system write failures are reported; the
app attempts to recover the previous clipboard while it still owns it.

## Pause, stop, sleep, and quit

| Action | What happens |
| --- | --- |
| Pause | Disables new recordings while keeping the model loaded. Resume makes dictation available again. Available when ready and not recording/transcribing. |
| Stop Dictation | Turns off recording, unloads the model, and discards audio waiting for retry. The latest displayed transcript remains. |
| Close the window / Quit | Quits the app and stops recording and its worker. The menu-bar item does not keep it running. |
| Mac sleeps / you switch out of your macOS user session | Stops dictation and discards audio waiting for retry. Start dictation again when you return. Switching between ordinary apps does not stop dictation. |
| Minimize the window | Keeps the session running. The ZK menu can show the window, stop dictation, or quit. |

Only one app instance runs at a time.

## Errors, retry, and privacy

If you released the dictation key and transcription fails, the app keeps that
recording in memory. **Retry Transcription** reloads the same model and tries the
same audio again. Stop, quit, sleep, or leaving your macOS user session discards
that audio. A successful transcription clears it too.

If the transcription service fails while you are still recording, that unfinished
recording is discarded. If no audio is waiting to be transcribed, **Retry** just
restarts the service.

The app does not save audio files or log audio or transcript content. Recordings
stay in memory while recording or waiting for retry. Text goes to the display
and your chosen clipboard or file output.

The app saves your preferences in
`~/Library/Application Support/ZK Dictate/settings.json` and keeps downloaded
models on disk for reuse. A small local diagnostic file contains permission
status, the app path, process ID, and check time. It contains no recordings or
transcripts.

Microphone and Input Monitoring approvals apply to the app. Rebuilding a locally
signed app can require reapproval even at the same path. If Input Monitoring looks
enabled but the hotkey fails after an update, remove the old entry, add
`~/Applications/ZK Dictate.app` again, and restart the app.

The installed app currently uses the downloaded source folder's Python environment.
Keep that folder in place. A portable, standalone app download is not yet provided.

# Release checks

## Automated

- [x] Python worker framing, audio validation, thread ownership, and cleanup tests.
- [x] Native hotkey, capture gate, settings, note creation, and append tests.
- [x] Real-model smoke tests using generated audio through Python and Swift pipes.
- [x] App build, signature verification, and source/package builds.

## Before a packaged release

- [ ] Microphone → transcript → clipboard tested in the current app.
- [ ] Folder selection, preferences after relaunch, and note/file output tested.
- [ ] Pause, Stop, close, quit, sleep, and retry tested together.
- [ ] Installation tested on a fresh Apple Silicon Mac.
- [ ] Upgrade permission behavior tested with a stable signing identity.
- [ ] Portable packaging and notarization completed.

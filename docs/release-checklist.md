# Release checks

## Automated in GitHub Actions

- [x] Python worker framing, audio validation, thread ownership, and cleanup tests.
- [x] Native hotkey, capture gate, settings, note creation, and append tests.
- [x] Clipboard sequences, expiry, cancellation, privacy markers, and image/rich-text
  round trips on an isolated named pasteboard.
- [x] App build, signature verification, and source/package builds.

## Local validation (not run in CI)

On 2026-09-08, both model revisions transcribed synthesized speech successfully,
including with Hugging Face offline mode enabled. These ad hoc smoke checks do not
exercise live microphone capture or replace the manual app checks below. CI uses
mocked model loading and does not run real-model or Swift worker-pipe integration.

## Before a packaged release

- [ ] Microphone → transcript → clipboard tested in the current app.
- [ ] Folder selection, preferences after relaunch, and note/file output tested.
- [ ] Pause, Stop, close, quit, sleep, and retry tested together.
- [ ] Installation tested on a fresh Apple Silicon Mac.
- [ ] Upgrade permission behavior tested with a stable signing identity.
- [ ] Portable packaging and notarization completed.

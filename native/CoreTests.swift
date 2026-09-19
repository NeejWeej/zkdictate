import Foundation
import Darwin

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct NativeTests {
    static func trySettings(_ value: AppSettings) -> AppSettings {
        try! AppSettings.fromData(JSONEncoder().encode(value))
    }
    static func main() throws {
        var session = DictationSession()
        session.pause(.lock)
        expect(!session.resume(.lock), "disabled dictation stays disabled")
        session.enabled = true
        session.pause(.lock); session.pause(.lock); session.pause(.sleep)
        expect(!session.resume(.sleep), "wake while locked cannot resume")
        expect(session.resume(.lock), "unlock resumes enabled dictation once")
        expect(!session.resume(.lock), "duplicate unlock cannot restart worker")
        session.pause(.userSession); session.pause(.sleep)
        expect(!session.resume(.userSession), "active session waits for wake")
        expect(session.resume(.sleep), "last pause reason resumes")
        session.pause(.lock); session.enabled = false
        expect(!session.resume(.lock), "explicit Stop during pause prevents resume")
        var fresh = FreshHotkey(waitingForRelease: true)
        expect(!fresh.allows(pressed: true), "held key cannot start on resume")
        expect(!fresh.allows(pressed: false), "first release cannot submit recording")
        expect(fresh.allows(pressed: true), "fresh press can start recording")
        // Hardware-like modifier edges must work without querying live keys.
        for (name, mask, side, other) in [("right_cmd", UInt64(0x100000), UInt64(0x10), UInt64(0x08)),
                                         ("left_cmd", 0x100000, 0x08, 0x10),
                                         ("right_alt", 0x80000, 0x40, 0x20),
                                         ("left_alt", 0x80000, 0x20, 0x40)] {
            expect(modifierHotkeyIsDown(name, flags: mask | side), "modifier press: \(name)")
            expect(!modifierHotkeyIsDown(name, flags: 0), "modifier release: \(name)")
            expect(!modifierHotkeyIsDown(name, flags: mask | other), "opposite side is not configured hotkey")
            expect(modifierHotkeyIsDown(name, flags: mask | side | other), "both sides held")
            expect(modifierHotkeyIsDown(name, flags: mask), "aggregate-only event supported")
        }
        for key in dictationKeys {
            let isModifier = key.aggregate != 0
            expect(recordableHotkey(code: key.code, flags: key.aggregate | key.side, modifierEvent: isModifier) == key.name, "record each supported single key")
            if isModifier {
                expect(recordableHotkey(code: key.code, flags: 0, modifierEvent: true) == nil, "release cannot select modifier")
                expect(!modifierHotkeyIsDown(key.name, flags: 0), "selected modifier releases capture")
                expect(recordableHotkey(code: key.code, flags: key.aggregate | key.pair, modifierEvent: true) == nil, "both sides rejected")
            }
        }
        for code: Int64 in [0, 1, 49, 36, 53, 57, 63, 123] {
            expect(recordableHotkey(code: code, flags: 0, modifierEvent: false) == nil, "typing/navigation keys rejected")
        }
        expect(recordableHotkey(code: 109, flags: 0x100010, modifierEvent: false) == nil, "Command plus F10 rejected")
        expect(recordableHotkey(code: 54, flags: 0x120012, modifierEvent: true) == nil, "two modifiers rejected")
        let migrated = try AppSettings.fromData(Data("{\"hotkey\":\"cmd\"}".utf8))
        expect(migrated.hotkey == "right_cmd", "either Command migrates to single key")
        for key in dictationKeys {
            var selected = AppSettings(); selected.hotkey = key.name
            let restored = try AppSettings.fromData(JSONEncoder().encode(selected))
            expect(restored.hotkey == key.name, "recorded key persists")
        }
        var contaminatedGate = CaptureGate()
        contaminatedGate.approved = true; contaminatedGate.ready = true
        if recordableHotkey(code: 54, flags: 0x100018, modifierEvent: true) == "right_cmd" {
            _ = contaminatedGate.press(now: 1)
        }
        expect(!contaminatedGate.recording, "pre-held left Command cannot start right Command capture")
        expect(!contaminatedGate.release(now: 3), "rejected shortcut cannot submit audio")
        expect(AppError("Run the installer again").localizedDescription == "Run the installer again", "actionable errors survive Cocoa localization")
        var eventGate = CaptureGate()
        eventGate.approved = true; eventGate.ready = true
        if modifierHotkeyIsDown("right_cmd", flags: 0x100010) { _ = eventGate.press(now: 1) }
        expect(eventGate.recording, "right-command event starts approved capture")
        if !modifierHotkeyIsDown("right_cmd", flags: 0) {
            expect(eventGate.release(now: 3), "right-command release accepts held recording")
        }
        expect(!eventGate.recording && !eventGate.ready, "release waits for transcription")
        var gate = CaptureGate()
        expect(!gate.press(now: 1), "capture requires dictation to be enabled")
        gate.approved = true
        expect(!gate.press(now: 1), "capture requires loaded model")
        gate.ready = true
        expect(gate.press(now: 1), "approved ready session starts")
        expect(!gate.press(now: 1.2), "repeat press must not restart capture")
        expect(!gate.release(now: 2), "short recording discarded")
        expect(gate.press(now: 3), "next recording available")
        gate.otherKey = true
        expect(!gate.release(now: 5), "other key discards recording")
        expect(gate.press(now: 6), "new recording resets accidental key guard")
        expect(gate.release(now: 8), "long clean recording accepted")
        expect(!gate.press(now: 9), "transcription blocks overlapping capture")
        gate.ready = true
        expect(gate.press(now: 10), "ready worker allows next capture")
        gate.approved = false
        expect(!gate.release(now: 12), "disconnect invalidates unfinished recording")
        gate.approved = true
        expect(gate.press(now: 20), "start duration-cap test")
        expect(!gate.release(now: 621), "long recording limit enforced")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try NoteOutput.save("first", folder: folder)
        let second = try NoteOutput.save("second", folder: folder)
        expect(first != second, "notes never overwrite each other")
        let firstText = try String(contentsOf: first, encoding: .utf8)
        expect(firstText == "first\n", "first note preserved")
        try NoteOutput.append("third", file: second)
        let secondText = try String(contentsOf: second, encoding: .utf8)
        expect(secondText == "second\nthird\n\n", "append preserves existing text")
        let defaultClipboard = try AppSettings.fromData(Data("{}".utf8))
        expect(!defaultClipboard.clipboardBackups && defaultClipboard.clipboardMinutes == 5, "clipboard backups opt-in with five-minute expiry")
        let validClipboard = try AppSettings.fromData(Data("{\"clipboard_backups\":true,\"clipboard_minutes\":15}".utf8))
        expect(validClipboard.clipboardBackups && validClipboard.clipboardMinutes == 15, "clipboard settings persist")
        let invalidClipboard = try AppSettings.fromData(Data("{\"clipboard_minutes\":999}".utf8))
        expect(invalidClipboard.clipboardMinutes == 5, "unsupported lifetime falls back to five minutes")
        expect(defaultClipboard.hidePreviewsOnDeactivate, "previews hide on focus loss by default")
        var previewSettings = AppSettings(); previewSettings.hidePreviewsOnDeactivate = false
        let previewRoundtrip = try AppSettings.fromData(JSONEncoder().encode(previewSettings))
        expect(!previewRoundtrip.hidePreviewsOnDeactivate, "preview privacy preference survives save and load")
        expect(!defaultClipboard.sideBySide, "layout defaults to tabs")
        var splitSettings = AppSettings(); splitSettings.sideBySide = true
        let splitRoundtrip = try AppSettings.fromData(JSONEncoder().encode(splitSettings))
        expect(splitRoundtrip.sideBySide, "side-by-side layout survives settings save and load")
        // Exercise the optional shortcut policy together with the real capture gate.
        expect(!defaultClipboard.finishAndPaste, "finish-and-paste defaults off for existing installations")
        var experimental = AppSettings(); experimental.finishAndPaste = true
        expect(trySettings(experimental).finishAndPaste, "feature flag survives settings roundtrip")
        var intent = FinishAndPaste()
        func key(_ code: Int64 = 9, flags: UInt64 = 0x100010, down: Bool = true,
                 modifier: Bool = false, repeated: Bool = false, enabled: Bool = true,
                 active: Bool = true) -> FinishAndPaste.Action {
            intent.key(code: code, flags: flags, down: down, modifier: modifier,
                       repeated: repeated, enabled: enabled, active: active)
        }
        expect(key(enabled: false) == .pass && !intent.pending, "flag off never intercepts Command-V")
        expect(key(active: false) == .pass, "idle Command-V remains normal paste")
        expect(key(flags: 0) == .pass, "plain V remains ordinary typing")
        expect(key(flags: 0x120000) == .pass, "Command-Shift-V is not the shortcut")
        expect(key(repeated: true) == .pass, "a key held before recording cannot request paste")
        var pasteGate = CaptureGate(); pasteGate.approved = true; pasteGate.ready = true
        expect(pasteGate.press(now: 1), "start shortcut recording")
        expect(key() == .request && intent.pending, "held Right Command plus V requests paste")
        expect(pasteGate.release(now: 3), "shortcut uses normal capture acceptance")
        expect(!pasteGate.release(now: 4), "physical hotkey release cannot submit twice")
        expect(key(54, flags: 0, down: false, modifier: true) == .pass && intent.pending, "hotkey release preserves intent")
        expect(key(repeated: true) == .swallow, "V autorepeat is suppressed")
        expect(intent.take() && !intent.take(), "successful copy consumes paste exactly once")
        expect(key(repeated: true, active: false) == .swallow, "repeat cannot paste twice after fast completion")
        expect(key(down: false, active: false) == .swallow, "matching V release is suppressed")
        expect(key(active: false) == .pass, "subsequent idle paste works")
        expect(key(flags: 0x100008) == .request, "left Command-V also queues during transcription")
        expect(key(down: false) == .swallow, "finish request key pair")
        expect(key(0, flags: 0) == .cancel && !intent.take(), "typing cancels pending paste but is passed to the app")
        expect(key() == .request, "explicit new request can requeue")
        expect(key(down: false) == .swallow, "release requeue key")
        expect(key(53, flags: 0) == .cancel && !intent.pending, "Escape cancels pending paste")
        for code: Int64 in [58, 59, 60] {
            expect(key() == .request, "queue modifier cancellation test")
            _ = key(down: false)
            let item = dictationKeys.first { $0.code == code }!
            expect(key(code, flags: item.aggregate | item.side, down: false, modifier: true) == .cancel,
                   "other modifier press cancels paste")
        }
        for (code, flags): (Int64, UInt64) in [(57, 0x10000), (63, 0x800000)] {
            expect(key() == .request, "queue caps lock/function cancellation")
            _ = key(down: false)
            expect(key(code, flags: flags, down: false, modifier: true) == .cancel, "caps lock and function cancel pending paste")
        }
        expect(key() == .request, "queue asynchronous clipboard copy")
        _ = key(down: false)
        expect(key(0, flags: 0) == .cancel && !intent.take(), "cancellation remains effective until clipboard copy completes")
        expect(key() == .request, "queue failure scenario")
        _ = key(down: false); intent.cancel()
        expect(!intent.take(), "empty result, failure, stop, or tap loss clears pending paste")
        // Real ordinary-paste sequence: right Command starts a tentative capture,
        // but V before the hold threshold must reach the destination unchanged.
        for elapsed in [0.01, 0.5, 1.499] {
            intent = FinishAndPaste(); pasteGate = CaptureGate()
            pasteGate.approved = true; pasteGate.ready = true
            expect(pasteGate.press(now: 10), "start tentative capture for ordinary paste")
            expect(key(active: pasteGate.canFinish(now: 10 + elapsed)) == .pass,
                   "quick Command-V passes through instead of swallowing the user's clipboard")
            pasteGate.otherKey = true // The normal event path still cancels this capture.
            expect(key(down: false, active: pasteGate.canFinish(now: 12)) == .pass, "ordinary V release passes through")
            expect(key(repeated: true, active: pasteGate.canFinish(now: 12)) == .pass, "held ordinary paste never turns into dictation")
            expect(!pasteGate.release(now: 12) && !intent.take(), "ordinary paste cannot later submit audio")
        }
        intent = FinishAndPaste(); pasteGate.ready = true
        expect(pasteGate.press(now: 20), "start deliberate recording")
        expect(key(active: pasteGate.canFinish(now: 21.5)) == .request, "exact hold threshold enables finish-and-paste")
        expect(pasteGate.release(now: 21.5), "eligible shortcut submits exactly once")
        _ = key(down: false); intent.cancel(); pasteGate.ready = true
        expect(pasteGate.press(now: 30), "start contaminated recording")
        pasteGate.otherKey = true
        expect(key(active: pasteGate.canFinish(now: 32)) == .pass, "cancelled recording must not intercept normal paste")
        expect(!pasteGate.release(now: 32) && !intent.take(), "paste cannot revive contaminated audio")
        expect(pasteGate.press(now: 40), "start maximum duration test")
        expect(!pasteGate.canFinish(now: 641), "expired capture cannot intercept paste")
        pasteGate.cancel()
        // Flag-off policy leaves legacy contamination and release behavior intact.
        intent = FinishAndPaste(); pasteGate.ready = true
        expect(pasteGate.press(now: 30), "start flag-off regression")
        if key(enabled: false) == .pass { pasteGate.otherKey = true }
        expect(!pasteGate.release(now: 32) && !intent.pending, "flag-off Command-V still cancels recording as before")
        expect(defaultClipboard.zoomPercent == 100, "existing settings default to normal zoom")
        var zoomSettings = AppSettings(); zoomSettings.zoomPercent = 130
        expect(trySettings(zoomSettings).zoomPercent == 130, "zoom persists across restart")
        let oversizedZoom = try AppSettings.fromData(Data("{\"zoom_percent\":999}".utf8))
        let undersizedZoom = try AppSettings.fromData(Data("{\"zoom_percent\":10}".utf8))
        expect(oversizedZoom.zoomPercent == 150 && undersizedZoom.zoomPercent == 80, "saved zoom is bounded")
        let settings = AppSettings()
        let roundtrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        expect(roundtrip.notesDirectory == settings.notesDirectory, "settings roundtrip")
        let oldSettings = try AppSettings.fromData(Data("{\"hotkey\":\"f10\"}".utf8))
        expect(oldSettings.model == .whisper8bit && oldSettings.hotkey == "f10", "old settings keep preferences and default model")
        expect(AppSettings().model == .whisper8bit, "new settings default to 8-bit")
        let explicitStandard = try AppSettings.fromData(Data("{\"model\":\"whisper\"}".utf8))
        expect(explicitStandard.model == .whisper, "explicit standard model selection preserved")
        var quantized = AppSettings(); quantized.model = .whisper8bit
        let restored = try AppSettings.fromData(JSONEncoder().encode(quantized))
        expect(restored.model == .whisper8bit, "8-bit choice persists")
        let unknown = try AppSettings.fromData(Data("{\"model\":\"removed-model\"}".utf8))
        expect(unknown.model == .whisper8bit, "unknown model falls back to default")
        print("Native hotkey, capture gate, settings, and note output tests passed (no capture APIs linked).")
    }
}

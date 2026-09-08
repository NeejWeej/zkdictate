import Foundation
import Darwin

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct NativeTests {
    static func main() throws {
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
        gate.ready = true; gate.paused = true
        expect(!gate.press(now: 9), "pause blocks capture")
        gate.paused = false
        expect(gate.press(now: 10), "resume allows capture")
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

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
        expect(modifierHotkeyIsDown("cmd", flags: 0x100008), "either command: left")
        expect(modifierHotkeyIsDown("cmd", flags: 0x100010), "either command: right")
        expect(!modifierHotkeyIsDown("cmd", flags: 0), "either command released")
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
        let settings = AppSettings()
        let roundtrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        expect(roundtrip.notesDirectory == settings.notesDirectory, "settings roundtrip")
        print("Native hotkey, capture gate, settings, and note output tests passed (no capture APIs linked).")
    }
}

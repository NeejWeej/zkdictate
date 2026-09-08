import Foundation

// Pure state machine: no audio, permission requests, or global input APIs.
struct CaptureGate {
    var approved = false
    var ready = false
    var paused = false
    var recording = false
    var started = 0.0
    var otherKey = false
    var minimumHold = 1.5
    let maximumHold = 600.0

    mutating func press(now: Double) -> Bool {
        guard approved && ready && !paused && !recording else { return false }
        recording = true; started = now; otherKey = false
        return true
    }
    mutating func cancel() { recording = false; otherKey = false }
    mutating func release(now: Double) -> Bool {
        guard recording else { return false }
        recording = false
        let accepted = approved && ready && !paused && !otherKey && now - started >= minimumHold && now - started <= maximumHold
        if accepted { ready = false }
        return accepted
    }
}

struct DictationKey {
    let name: String
    let title: String
    let code: Int64
    let aggregate: UInt64
    let side: UInt64
    let pair: UInt64
}

let dictationKeys: [DictationKey] = [
    DictationKey(name: "right_cmd", title: "Right Command", code: 54, aggregate: 0x100000, side: 0x10, pair: 0x18),
    DictationKey(name: "left_cmd", title: "Left Command", code: 55, aggregate: 0x100000, side: 0x08, pair: 0x18),
    DictationKey(name: "right_alt", title: "Right Option", code: 61, aggregate: 0x80000, side: 0x40, pair: 0x60),
    DictationKey(name: "left_alt", title: "Left Option", code: 58, aggregate: 0x80000, side: 0x20, pair: 0x60),
    DictationKey(name: "right_shift", title: "Right Shift", code: 60, aggregate: 0x20000, side: 0x04, pair: 0x06),
    DictationKey(name: "left_shift", title: "Left Shift", code: 56, aggregate: 0x20000, side: 0x02, pair: 0x06),
    DictationKey(name: "right_ctrl", title: "Right Control", code: 62, aggregate: 0x40000, side: 0x2000, pair: 0x2001),
    DictationKey(name: "left_ctrl", title: "Left Control", code: 59, aggregate: 0x40000, side: 0x01, pair: 0x2001),
] + [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90].enumerated().map {
    DictationKey(name: "f\($0.offset + 1)", title: "F\($0.offset + 1)", code: Int64($0.element), aggregate: 0, side: 0, pair: 0)
}
let allowedHotkeys = Dictionary(uniqueKeysWithValues: dictationKeys.map { ($0.name, Set([$0.code])) })
func hotkeyTitle(_ name: String) -> String { dictationKeys.first { $0.name == name }?.title ?? "Right Command" }

// Decode event flags, never live keyboard state: live polling can miss an edge.
// Side masks are defined in Apple's IOKit/hidsystem/IOLLEvent.h.
func modifierHotkeyIsDown(_ hotkey: String, flags: UInt64) -> Bool {
    guard let key = dictationKeys.first(where: { $0.name == hotkey }), key.aggregate != 0,
          flags & key.aggregate != 0 else { return false }
    // Some event sources supply aggregate-only flags.
    return flags & key.pair == 0 || flags & key.side != 0
}

func recordableHotkey(code: Int64, flags: UInt64, modifierEvent: Bool) -> String? {
    guard let key = dictationKeys.first(where: { $0.code == code }) else { return nil }
    let heldModifiers = flags & 0x1e0000 // Command, Option, Control, Shift
    if key.aggregate == 0 {
        return !modifierEvent && heldModifiers == 0 ? key.name : nil
    }
    guard modifierEvent, heldModifiers == key.aggregate,
          modifierHotkeyIsDown(key.name, flags: flags),
          flags & key.pair & ~key.side == 0 else { return nil }
    return key.name
}

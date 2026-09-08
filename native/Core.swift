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

let allowedHotkeys: [String: Set<Int64>] = [
    "right_cmd": [54], "left_cmd": [55], "cmd": [54, 55],
    "right_alt": [61], "left_alt": [58], "f10": [109]
]
// Decode the flags carried by the event itself. Polling global keyboard state
// inside a listen-only callback can classify both edges as released.
// Masks are defined in Apple's IOKit/hidsystem/IOLLEvent.h.
func modifierHotkeyIsDown(_ hotkey: String, flags: UInt64) -> Bool {
    let aggregate: UInt64
    let side: UInt64
    let pair: UInt64
    switch hotkey {
    case "cmd": return flags & 0x00100000 != 0
    case "right_cmd": (aggregate, side, pair) = (0x00100000, 0x10, 0x18)
    case "left_cmd": (aggregate, side, pair) = (0x00100000, 0x08, 0x18)
    case "right_alt": (aggregate, side, pair) = (0x00080000, 0x40, 0x60)
    case "left_alt": (aggregate, side, pair) = (0x00080000, 0x20, 0x60)
    default: return false
    }
    guard flags & aggregate != 0 else { return false }
    // Events without device-specific bits still carry the aggregate modifier.
    return flags & pair == 0 ? true : flags & side != 0
}

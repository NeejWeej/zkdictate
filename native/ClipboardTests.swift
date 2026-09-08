import AppKit

func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
    if (try? value()) != true { fatalError(message) }
}
func waitFor(_ condition: () -> Bool) {
    let end = Date().addingTimeInterval(5)
    while !condition() && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    check(condition(), "Clipboard operation did not finish")
}
func perform(_ action: (@escaping (Result<Void, Error>) -> Void) -> Void, succeeds: Bool = true) {
    var result: Result<Void, Error>?
    action { result = $0 }
    waitFor { result != nil }
    switch result! {
    case .success: check(succeeds, "Expected clipboard operation to fail")
    case .failure(let error): check(!succeeds, "Unexpected error: \(error)")
    }
}

final class TestClipboard: ClipboardAccess {
    private let lock = NSLock()
    private var payload = ClipboardPayload(items: [])
    private var count = 0
    var afterRead: (() -> Void)?
    var readError: Error?
    var refuseWrite = false
    var changeCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var contents: ClipboardPayload { lock.lock(); defer { lock.unlock() }; return payload }
    func external(_ value: ClipboardPayload) { lock.lock(); defer { lock.unlock() }; count += 1; payload = value }
    func read(expected: Int) throws -> ClipboardPayload {
        if let readError { throw readError }
        lock.lock(); let copy = payload; let version = count; lock.unlock()
        guard version == expected else { throw ClipboardFailure.changed }
        afterRead?()
        return copy
    }
    func write(_ payload: ClipboardPayload, expected: Int, rollback: ClipboardPayload?) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard count == expected else { throw ClipboardFailure.changed }
        if refuseWrite { throw ClipboardFailure.writeFailed }
        count += 1; self.payload = payload; return count
    }
}

@main struct ClipboardTests {
    static func main() throws {
        var time: TimeInterval = 100
        let board = TestClipboard()
        let manager = ClipboardManager(clipboard: board, now: { time })
        check(!manager.enabled, "Backups default off")
        board.external(.text("A"))
        perform { manager.copy("off", completion: $0) }
        check(manager.lastCopy == nil && manager.beforeDictation == nil, "Disabled copies retain no backups")
        manager.configure(enabled: true, minutes: 5)
        board.external(.text("A"))
        perform { manager.copy("D1", completion: $0) }
        check(manager.lastCopy?.payload == .text("A") && manager.beforeDictation?.payload == .text("A"), "First dictation backs up external copy twice")
        time += 10
        perform { manager.copy("D2", completion: $0) }
        check(manager.lastCopy?.payload == .text("D1") && manager.beforeDictation?.payload == .text("A"), "Second dictation keeps original external copy")
        board.external(.text("B")); manager.tick()
        check(!manager.canRestore(.lastCopy) && !manager.canRestore(.beforeDictation), "External copy blocks both restores")
        perform({ manager.restore(.beforeDictation, completion: $0) }, succeeds: false)
        check(board.contents == .text("B"), "Failed restore preserves newer external clipboard")
        perform { manager.copy("D3", completion: $0) }
        check(manager.lastCopy?.payload == .text("B") && manager.beforeDictation?.payload == .text("B"), "copy/dictation/dictation/copy/dictation yields second copy in both slots")
        let captured = manager.beforeDictation!.capturedAt
        let id = manager.lastCopy!.id
        time += 10
        perform { manager.copy("D3", completion: $0) }
        check(manager.lastCopy?.id == id && manager.beforeDictation?.capturedAt == captured, "Repeated copy does not replace backup or renew expiry")
        perform { manager.copy("D4", completion: $0) }
        perform { manager.restore(.lastCopy, completion: $0) }
        check(board.contents == .text("D3"), "Restore last copy")
        perform { manager.restore(.beforeDictation, completion: $0) }
        check(board.contents == .text("B"), "Can switch to other restore after first restore")
        perform { manager.restore(.lastCopy, completion: $0) }
        check(board.contents == .text("D3"), "Can switch back without erasing either backup")
        time = captured + 300; manager.tick()
        check(manager.beforeDictation == nil && manager.lastCopy != nil, "Original expires independently despite repeated dictation/restore")
        time += 20; manager.tick()
        check(manager.lastCopy == nil, "Last-copy payload expires too")
        board.external(.text("short-lived")); perform { manager.copy("D5", completion: $0) }
        time += 61; manager.configure(enabled: true, minutes: 1)
        check(manager.lastCopy == nil && manager.beforeDictation == nil, "Shortening TTL expires existing payloads immediately")
        manager.configure(enabled: true, minutes: 5)
        board.external(.text("clear me")); perform { manager.copy("D6", completion: $0) }
        manager.clear()
        check(manager.lastCopy == nil && manager.beforeDictation == nil, "Clear releases both backups")
        check(board.contents == .text("D6"), "Clear does not erase system clipboard")
        perform { manager.copy("D7", completion: $0) }
        check(manager.beforeDictation == nil, "Our transcript does not become external after clearing")
        board.external(.text("external")); perform { manager.copy("D8", completion: $0) }
        manager.configure(enabled: false, minutes: 5)
        check(manager.lastCopy == nil && manager.beforeDictation == nil, "Disabling releases backups")
        manager.configure(enabled: true, minutes: 5)
        board.external(.text("race"))
        board.afterRead = { board.external(.text("newer")) }
        perform({ manager.copy("must not copy", completion: $0) }, succeeds: false)
        check(board.contents == .text("newer"), "Clipboard changes during read are preserved")
        board.afterRead = nil
        board.readError = ClipboardFailure.protectedContent
        perform({ manager.copy("private", completion: $0) }, succeeds: false)
        check(manager.lastCopy == nil && manager.beforeDictation == nil && board.contents == .text("newer"), "Protected clipboard is neither saved nor overwritten")
        board.readError = nil
        board.refuseWrite = true
        perform({ manager.copy("fail", completion: $0) }, succeeds: false)
        check(board.contents == .text("newer"), "Write failure reported")
        board.refuseWrite = false
        let latch = DispatchSemaphore(value: 0)
        board.afterRead = { latch.wait() }
        var cancelled = false
        manager.copy("cancelled") { _ in cancelled = true }
        manager.clear(); latch.signal()
        waitFor { cancelled }
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        check(board.contents == .text("newer"), "In-flight result cannot write after clear/lock/disable")
        board.afterRead = nil

        let stalled = TestClipboard()
        stalled.external(.text("unchanged"))
        let stalledManager = ClipboardManager(clipboard: stalled)
        stalledManager.configure(enabled: true, minutes: 5)
        let release = DispatchSemaphore(value: 0)
        stalled.afterRead = { release.wait() }
        var timedOut = false
        stalledManager.copy("late") { result in
            if case .failure(ClipboardFailure.timedOut) = result { timedOut = true }
        }
        waitFor { timedOut }
        check(stalled.contents == .text("unchanged") && !stalledManager.busy, "Slow provider times out without blocking UI or writing")
        release.signal()
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        check(stalled.contents == .text("unchanged") && stalledManager.lastCopy == nil, "Late results cannot resurrect expired operation")

        // Integration uses a unique named pasteboard, never the user's general clipboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("zkdictate-tests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let system = SystemClipboard(pasteboard)
        let actual = ClipboardManager(clipboard: system)
        actual.configure(enabled: true, minutes: 5)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let rich = ClipboardPayload(items: [[NSPasteboard.PasteboardType.png.rawValue: png, NSPasteboard.PasteboardType.string.rawValue: Data("image caption".utf8), "public.rtf": Data("{\\rtf1 caption}".utf8)], [NSPasteboard.PasteboardType.fileURL.rawValue: Data("file:///tmp/example.txt".utf8)]])
        _ = try system.write(rich, expected: system.changeCount)
        let card = ClipboardPreview(title: "Restore", target: NSObject(), action: NSSelectorFromString("unused"))
        let imageBackup = ClipboardBackup(payload: ClipboardPayload(items: [[NSPasteboard.PasteboardType.png.rawValue: png]]), capturedAt: 0, isTranscript: false)
        card.update(imageBackup, visible: false, seconds: 10, canRestore: true)
        check(card.picture.image == nil && card.preview.stringValue.isEmpty, "Previews never decoded while hidden")
        card.update(imageBackup, visible: true, seconds: 10, canRestore: true)
        check(card.picture.image != nil && !card.picture.isHidden, "Image preview uses downsampled thumbnail")
        card.update(nil, visible: true, seconds: 0, canRestore: false)
        check(card.picture.image == nil && card.preview.stringValue.isEmpty && !card.restore.isEnabled, "Expiry clears thumbnail and text preview")
        let textBackup = ClipboardBackup(payload: .text(String(repeating: "x", count: 1000)), capturedAt: 0, isTranscript: false)
        card.update(textBackup, visible: true, seconds: 10, canRestore: true)
        check(card.preview.stringValue.count <= 300, "Text previews bounded")
        card.update(textBackup, visible: false, seconds: 10, canRestore: true)
        check(card.preview.stringValue.isEmpty, "Hiding previews removes displayed text")
        let original = try system.read(expected: system.changeCount)
        perform { actual.copy("image replaced", completion: $0) }
        perform { actual.copy("second transcript", completion: $0) }
        check(actual.beforeDictation?.payload == original && actual.lastCopy?.payload == .text("image replaced"), "Real pasteboard ownership distinguishes our copies")
        perform { actual.restore(.beforeDictation, completion: $0) }
        check(try system.read(expected: system.changeCount) == original, "All image, rich text, file URL, and multiple-item bytes round-trip")
        let empty = ClipboardPayload(items: [])
        _ = try system.write(empty, expected: system.changeCount)
        perform { actual.copy("was empty", completion: $0) }
        perform { actual.restore(.beforeDictation, completion: $0) }
        check(try system.read(expected: system.changeCount) == empty, "Empty clipboard restores as empty")
        for marker in SystemClipboard.excludedTypes where !marker.contains(" ") {
            _ = try system.write(ClipboardPayload(items: [[marker: Data(), NSPasteboard.PasteboardType.string.rawValue: Data("sensitive".utf8)]]), expected: system.changeCount)
            let count = system.changeCount
            perform({ actual.copy("no", completion: $0) }, succeeds: false)
            check(system.changeCount == count && actual.lastCopy == nil, "Privacy marker never overwritten or captured")
        }
        _ = try system.write(ClipboardPayload(items: [["public.data": Data(count: ClipboardPayload.maximumBytes + 1)]]), expected: system.changeCount)
        let count = system.changeCount
        perform({ actual.copy("too big", completion: $0) }, succeeds: false)
        check(system.changeCount == count, "Oversize content remains untouched")
        print("Clipboard sequence, provenance, expiry, cancellation, races, privacy markers, and real named-pasteboard format tests passed.")
    }
}

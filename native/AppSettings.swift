import Foundation

enum TranscriptionModel: String, Codable, CaseIterable {
    case whisper = "whisper"
    case whisper8bit = "whisper-8bit"
    var title: String { self == .whisper ? "Whisper Turbo" : "Whisper Turbo (8-bit, Default)" }
}

struct AppSettings: Codable {
    var notesDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ZK Dictate").path
    var outputMode = "clipboard"
    var filePath: String? = nil
    var hotkey = "right_cmd"
    var beep = false
    var clipboardBackups = false
    var clipboardMinutes = 5
    var sideBySide = false
    var hidePreviewsOnDeactivate = true
    var model = TranscriptionModel.whisper8bit
    enum CodingKeys: String, CodingKey {
        case notesDirectory = "notes_directory", outputMode = "output_mode", filePath = "file_path", hotkey, beep, model, clipboardBackups = "clipboard_backups", clipboardMinutes = "clipboard_minutes", sideBySide = "side_by_side", hidePreviewsOnDeactivate = "hide_previews_on_deactivate"
    }
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ZK Dictate/settings.json") }
    static func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppSettings() }
        return try fromData(Data(contentsOf: url))
    }
    static func fromData(_ data: Data) throws -> AppSettings {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError("Invalid settings file") }
        var result = AppSettings()
        if let path = values["notes_directory"] as? String {
            guard path.hasPrefix("/") else { throw AppError("Invalid notes folder") }; result.notesDirectory = path
        }
        if let mode = values["output_mode"] as? String, ["clipboard", "note", "file"].contains(mode) { result.outputMode = mode }
        if let path = values["file_path"] as? String, path.hasPrefix("/") { result.filePath = path }
        if let hotkey = values["hotkey"] as? String, allowedHotkeys[hotkey] != nil { result.hotkey = hotkey }
        // The retired either-side option becomes one explicit key.
        if values["hotkey"] as? String == "cmd" { result.hotkey = "right_cmd" }
        result.hidePreviewsOnDeactivate = values["hide_previews_on_deactivate"] as? Bool ?? true
        result.sideBySide = values["side_by_side"] as? Bool ?? false
        result.clipboardBackups = values["clipboard_backups"] as? Bool ?? false
        if let minutes = values["clipboard_minutes"] as? Int, [1, 5, 15].contains(minutes) { result.clipboardMinutes = minutes }
        result.beep = values["beep"] as? Bool ?? false
        result.model = (values["model"] as? String).flatMap(TranscriptionModel.init(rawValue:)) ?? .whisper8bit
        return result
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }
}

struct NoteOutput {
    static func save(_ text: String, folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = DateFormatter(); format.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appendingPathComponent("\(format.string(from: Date()))-\(UUID().uuidString.prefix(8)).md")
        // Exclusive creation: repeated dictations can never overwrite a note.
        try Data((text + "\n").utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    static func append(_ text: String, file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data().write(to: file, options: .withoutOverwriting)
        }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((text + "\n\n").utf8))
    }
}

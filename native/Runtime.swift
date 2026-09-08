import Foundation

let appCacheDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.zkdictate.recorder")

struct AppError: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
    init(_ message: String) { description = message }
}

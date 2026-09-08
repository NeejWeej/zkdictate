import Foundation

let appCacheDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.zkdictate.recorder")

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

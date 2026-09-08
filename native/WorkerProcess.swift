import Foundation

/// Owns one private transcription service. Communicates over inherited pipes.
final class WorkerProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writer = DispatchQueue(label: "com.zkdictate.worker.write")
    private var stopping = false
    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?

    func start() throws {
        guard let python = Bundle.main.object(forInfoDictionaryKey: "ZKPythonExecutable") as? String,
              FileManager.default.isExecutableFile(atPath: python),
              let script = Bundle.main.url(forResource: "app_worker", withExtension: "py") else {
            throw AppError("Python environment is missing. Run install.sh from the source checkout.")
        }
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", script.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        var environment = ProcessInfo.processInfo.environment
        for name in ["PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"] { environment.removeValue(forKey: name) }
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { guard let self, !self.stopping else { return }; self.onExit?(process.terminationStatus) }
        }
        try process.run()
        // Close unused pipe ends so EOF has an unambiguous lifetime meaning.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        DispatchQueue.global().async { [weak self, output] in
            var pending = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                if pending.count > 2 * 1024 * 1024 {
                    DispatchQueue.main.async { self?.onEvent?(["event": "fatal", "message": "Worker response exceeded size limit"] ) }; break
                }
                while let end = pending.firstIndex(of: 10) {
                    guard let object = try? JSONSerialization.jsonObject(with: pending[..<end]) as? [String: Any] else {
                        DispatchQueue.main.async { self?.onEvent?(["event": "fatal", "message": "Invalid worker response"] ) }; return
                    }
                    pending.removeSubrange(...end)
                    DispatchQueue.main.async { self?.onEvent?(object) }
                }
            }
            try? output.fileHandleForReading.close()
        }
        // Drain progress output to prevent a full stderr pipe blocking MLX.
        DispatchQueue.global().async { [errors] in
            while !errors.fileHandleForReading.availableData.isEmpty {}
            try? errors.fileHandleForReading.close()
        }
    }
    func transcribe(_ audio: Data, id: String) {
        writer.async { [weak self] in
            guard let self else { return }
            do {
                var data = try JSONSerialization.data(withJSONObject: ["command": "transcribe", "id": id, "audio": audio.base64EncodedString()])
                data.append(10)
                try self.input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                DispatchQueue.main.async { self.onEvent?(["event": "fatal", "message": "Transcription worker disconnected"]) }
            }
        }
    }
    func stop() {
        stopping = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    deinit { stop() }
}

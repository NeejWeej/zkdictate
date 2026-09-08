import Foundation
import AVFoundation

final class Recorder {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples = Data()
    private var failed = false
    private var accepting = false
    private let maxBytes = 16000 * 4 * 600

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AppError("Microphone permission is required in ZK Dictate.app")
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else { throw AppError("No usable microphone input") }
        lock.lock(); samples = Data(); failed = false; accepting = true; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / format.sampleRate) + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.accepting else { return }
            if status == .error || error != nil { self.failed = true; return }
            if let channel = converted.floatChannelData?[0] {
                let bytes = Int(converted.frameLength) * MemoryLayout<Float>.size
                if self.samples.count + bytes <= self.maxBytes {
                    self.samples.append(UnsafeBufferPointer(start: UnsafeRawPointer(channel).assumingMemoryBound(to: UInt8.self), count: bytes))
                } else { self.failed = true }
            }
        }
        do { try engine.start(); self.engine = engine }
        catch { input.removeTap(onBus: 0); engine.stop(); lock.lock(); accepting = false; samples = Data(); lock.unlock(); throw error }
    }

    func stop(discard: Bool) -> Data? {
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        lock.lock(); defer { lock.unlock() }
        accepting = false
        defer { samples = Data() }
        return discard || failed || samples.isEmpty ? nil : samples
    }
}

import AVFoundation
import Darwin
import Foundation

/// All methods must be called on the same serial audio queue.
public final class AudioFileRecorder {
    public let url: URL
    public let outputFormat: RecordingFormat
    public private(set) var frameCount: AVAudioFramePosition = 0
    public private(set) var finishError: Error?
    public var duration: TimeInterval { Double(frameCount) / (format?.sampleRate ?? 48_000) }
    private var file: AVAudioFile?
    private var mp3: MP3FileWriter?
    private var format: AVAudioFormat?
    private var originTimestamp: TimeInterval?
    private var closed = false
    private var reservedPath = false
    private let maxDataBytes: Int64

    public init(url: URL, outputFormat: RecordingFormat = .wav, maxDataBytes: Int64 = 3_600_000_000) throws {
        self.url = url
        self.outputFormat = outputFormat
        self.maxDataBytes = maxDataBytes
        // The container is determined by the file extension. Reject mismatches
        // before reserving any path, rather than silently writing another format.
        guard outputFormat.acceptsExtension(url.pathExtension) else { throw AudioError.fileExtensionMismatch }
        // Reserve a new path exclusively: never truncate an existing user file.
        let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw AudioError.fileExists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        reservedPath = true
        Darwin.close(descriptor)
    }

    public func append(_ buffer: AVAudioPCMBuffer, timestamp: TimeInterval? = nil) throws {
        guard !closed else { throw AudioError.finished }
        guard buffer.frameLength > 0 else { return }
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { throw AudioError.unsupportedFormat }
        if let format {
            guard format == buffer.format else { throw AudioError.formatChanged }
        } else {
            format = buffer.format
            if outputFormat == .mp3 {
                mp3 = try MP3FileWriter(url: url, format: buffer.format)
            } else {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: outputFormat.encoderSettings(sampleRate: buffer.format.sampleRate, channels: buffer.format.channelCount),
                    commonFormat: .pcmFormatFloat32,
                    interleaved: buffer.format.isInterleaved
                )
            }
        }
        if let timestamp, timestamp.isFinite {
            if originTimestamp == nil {
                originTimestamp = timestamp - duration
            }
            let relativeFrames = ((timestamp - originTimestamp!) * buffer.format.sampleRate).rounded()
            let limit = Double(maxDataBytes / Int64(buffer.format.channelCount * 4))
            guard relativeFrames >= -2 else { throw AudioError.timelineReversed }
            guard relativeFrames <= limit else { throw AudioError.sizeLimit }
            let target = AVAudioFramePosition(relativeFrames)
            let missing = target - frameCount
            // Tolerate rounding jitter of up to two audio frames.
            if missing < -2 { throw AudioError.timelineReversed }
            if missing > 2 { try writeSilence(frames: missing) }
        }
        try write(buffer)
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        let proposedBytes = (frameCount + Int64(buffer.frameLength)) * Int64(buffer.format.channelCount * 4)
        guard proposedBytes <= maxDataBytes else { throw AudioError.sizeLimit }
        if let mp3 { try mp3.write(buffer) }
        else { try file!.write(from: buffer) }
        frameCount += Int64(buffer.frameLength)
    }

    private func writeSilence(frames: AVAudioFramePosition) throws {
        guard let format, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw AudioError.invalidBuffer
        }
        silence.frameLength = silence.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(4096, remaining))
            try write(silence)
            remaining -= Int64(silence.frameLength)
        }
    }

    /// Releasing AVAudioFile flushes encoder packets and finalizes the container.
    @discardableResult
    public func finish() -> URL? {
        guard !closed else { return frameCount > 0 ? url : nil }
        closed = true
        if let mp3 {
            do { try mp3.finish() }
            catch { finishError = error }
            self.mp3 = nil
        }
        file = nil
        // A throwing initializer also runs deinit; it must not delete an unowned path.
        if frameCount == 0 && reservedPath { try? FileManager.default.removeItem(at: url) }
        return frameCount > 0 ? url : nil
    }

    deinit { finish() }
}

// Keep the first learning version's sample code and tests source-compatible.
public typealias WAVRecorder = AudioFileRecorder

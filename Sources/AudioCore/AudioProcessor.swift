import AVFoundation
import CoreMedia
import Foundation

public enum AudioError: LocalizedError {
    case unsupportedFormat, invalidBuffer, formatChanged, timelineReversed
    case fileExists, sizeLimit, finished, fileExtensionMismatch
    case copyFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "收到的音频不是支持的 32 位浮点 PCM 格式。"
        case .invalidBuffer: return "音频缓冲区无效。"
        case .formatChanged: return "音源的采样格式发生变化。已有录音已保留，请重新开始。"
        case .timelineReversed: return "音源的时间戳发生跳变。已有录音已保留，请重新开始。"
        case .fileExists: return "文件已存在。为保护原文件，请使用一个新的文件名。"
        case .sizeLimit: return "录音已达到本版本的单次长度上限，已有内容已保留。请开始一个新文件。"
        case .fileExtensionMismatch: return "文件扩展名与所选录音格式不一致，请使用所选格式对应的扩展名。"
        case .finished: return "该录音已经结束。"
        case .copyFailed(let status): return "无法读取音频数据（\(status)）。"
        }
    }
}

public struct MeterReading: Sendable {
    public let peaks: [Float]
    public let clipped: Bool
    public static let silence = MeterReading(peaks: [0, 0], clipped: false)

    public init(peaks: [Float], clipped: Bool) {
        self.peaks = peaks
        self.clipped = clipped
    }
}

public enum AudioProcessor {
    /// Copies the system-owned sample before applying any in-place processing.
    public static func copyPCM(from sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample) else {
            throw AudioError.invalidBuffer
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= Int(Int32.max),
              format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw AudioError.unsupportedFormat
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { throw AudioError.copyFailed(status) }
        return buffer
    }

    /// Hard clipping is a last-resort output guard, not a compressor or true-peak limiter.
    @discardableResult
    public static func process(_ buffer: AVAudioPCMBuffer, gain: Float, muted: Bool) throws -> MeterReading {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let data = buffer.floatChannelData else { throw AudioError.unsupportedFormat }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let multiplier: Float = muted ? 0 : (gain.isFinite ? min(2, max(0, gain)) : 0)
        var peaks = [Float](repeating: 0, count: channels)
        var clipped = false
        for channel in 0..<channels {
            let samples = buffer.format.isInterleaved ? data[0] : data[channel]
            let stride = buffer.format.isInterleaved ? channels : 1
            let offset = buffer.format.isInterleaved ? channel : 0
            for frame in 0..<frames {
                let index = frame * stride + offset
                let raw = samples[index] * multiplier
                let finite = raw.isFinite ? raw : 0
                if abs(finite) > 1 { clipped = true }
                let output = min(1, max(-1, finite))
                samples[index] = output
                peaks[channel] = max(peaks[channel], abs(output))
            }
        }
        return MeterReading(peaks: peaks, clipped: clipped)
    }
}

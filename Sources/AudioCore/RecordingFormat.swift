import AVFoundation
import Foundation

public enum RecordingFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case wav, m4a, aiff, mp3
    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var menuTitle: String {
        switch self {
        case .wav: return "WAV · 32 位浮点，无压缩"
        case .m4a: return "M4A · AAC 256 kbps，小体积"
        case .aiff: return "AIFF · 24 位 PCM，无压缩"
        case .mp3: return "MP3 · 320 kbps，通用播放"
        }
    }
    public var detail: String {
        switch self {
        case .wav: return "48 kHz · 双声道 · 32 位浮点 PCM"
        case .m4a: return "48 kHz · 双声道 · AAC，目标 256 kbps"
        case .aiff: return "48 kHz · 双声道 · 24 位整数 PCM"
        case .mp3: return "48 kHz · 双声道 · MP3，320 kbps"
        }
    }
    public func acceptsExtension(_ value: String) -> Bool {
        switch self {
        case .wav: return ["wav", "wave"].contains(value.lowercased())
        case .m4a: return value.lowercased() == "m4a"
        case .aiff: return ["aiff", "aif"].contains(value.lowercased())
        case .mp3: return value.lowercased() == "mp3"
        }
    }
    public func encoderSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ]
        if self == .mp3 {
            // MP3 uses the bundled streaming writer, not AVAudioFile encoding.
            settings[AVFormatIDKey] = kAudioFormatMPEGLayer3
            settings[AVEncoderBitRateKey] = 320_000
        } else if self == .m4a {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 256_000
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        } else {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = self == .wav ? 32 : 24
            settings[AVLinearPCMIsFloatKey] = self == .wav
            settings[AVLinearPCMIsBigEndianKey] = self == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        return settings
    }
}

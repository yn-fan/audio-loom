import AVFoundation
import Foundation

public struct WaveformBin: Equatable, Sendable {
    public let minimum: Float
    public let maximum: Float
    public init(minimum: Float, maximum: Float) {
        self.minimum = minimum
        self.maximum = maximum
    }
    public static let silence = WaveformBin(minimum: 0, maximum: 0)
}

/// A bounded, time-based envelope of actual PCM samples. Stereo extrema are
/// combined rather than averaged, so opposite-phase channels remain visible.
/// The UI receives only 96 min/max pairs, never raw audio buffers.
public struct WaveformEnvelope {
    public let capacity: Int
    private let binSeconds: Double
    private var sampleRate: Double = 0
    private var framesPerBin = 1
    private var bins: [WaveformBin] = []
    private var partialFrames = 0
    private var low: Float = 1
    private var high: Float = -1
    private var expectedTimestamp: Double?

    public init(capacity: Int = 96, binSeconds: Double = 0.02) {
        self.capacity = max(1, min(512, capacity))
        self.binSeconds = binSeconds.isFinite ? min(1, max(0.001, binSeconds)) : 0.02
    }

    public var snapshot: [WaveformBin] {
        var result = bins
        if partialFrames > 0 { result.append(WaveformBin(minimum: low, maximum: high)) }
        result = Array(result.suffix(capacity))
        return Array(repeating: .silence, count: max(0, capacity - result.count)) + result
    }

    public mutating func append(_ buffer: AVAudioPCMBuffer, timestamp: Double? = nil) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.sampleRate > 0, buffer.format.sampleRate <= 768_000, buffer.format.sampleRate.isFinite,
              let data = buffer.floatChannelData else { throw AudioError.unsupportedFormat }
        guard buffer.frameLength > 0 else { return }
        if sampleRate != buffer.format.sampleRate {
            sampleRate = buffer.format.sampleRate
            framesPerBin = max(1, Int((sampleRate * binSeconds).rounded()))
            clear()
        }
        if let timestamp, timestamp.isFinite {
            if let expectedTimestamp {
                let gap = (timestamp - expectedTimestamp) * sampleRate
                if gap < -2 {
                    clear()
                } else if gap > 2 {
                    // Bound work for a sleeping/disconnected source. Old audio
                    // is outside the visible history after one full window.
                    let visibleFrames = capacity * framesPerBin
                    if gap >= Double(visibleFrames) {
                        bins = Array(repeating: .silence, count: capacity)
                        resetPartial()
                    } else {
                        appendSilence(frames: Int(gap.rounded()))
                    }
                }
            }
            expectedTimestamp = timestamp + Double(buffer.frameLength) / sampleRate
        } else {
            expectedTimestamp = nil
        }
        let channels = Int(buffer.format.channelCount)
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<channels {
                let raw = buffer.format.isInterleaved
                    ? data[0][frame * channels + channel]
                    : data[channel][frame]
                let value = raw.isFinite ? min(1, max(-1, raw)) : 0
                low = min(low, value)
                high = max(high, value)
            }
            partialFrames += 1
            if partialFrames == framesPerBin { finishBin() }
        }
    }

    private mutating func clear() {
        bins.removeAll(keepingCapacity: true)
        expectedTimestamp = nil
        resetPartial()
    }

    private mutating func resetPartial() {
        partialFrames = 0
        low = 1
        high = -1
    }

    private mutating func finishBin() {
        bins.append(WaveformBin(minimum: low, maximum: high))
        if bins.count > capacity { bins.removeFirst(bins.count - capacity) }
        resetPartial()
    }

    private mutating func appendSilence(frames: Int) {
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, framesPerBin - partialFrames)
            low = min(low, 0)
            high = max(high, 0)
            partialFrames += count
            remaining -= count
            if partialFrames == framesPerBin { finishBin() }
        }
    }
}

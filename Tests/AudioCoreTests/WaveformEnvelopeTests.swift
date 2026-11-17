import AVFoundation
import XCTest
@testable import AudioCore

final class WaveformEnvelopeTests: XCTestCase {
    private func pcm(_ channels: [[Float]], interleaved: Bool = false, rate: Double = 1000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: AVAudioChannelCount(channels.count), interleaved: interleaved)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        pcm.frameLength = pcm.frameCapacity
        for channel in channels.indices {
            for frame in channels[channel].indices {
                if interleaved { pcm.floatChannelData![0][frame * channels.count + channel] = channels[channel][frame] }
                else { pcm.floatChannelData![channel][frame] = channels[channel][frame] }
            }
        }
        return pcm
    }

    func testInitialAndSilentWaveformAreFlat() throws {
        var wave = WaveformEnvelope()
        XCTAssertEqual(wave.snapshot.count, 96)
        XCTAssertTrue(wave.snapshot.allSatisfy { $0 == .silence })
        try wave.append(pcm([[Float](repeating: 0, count: 100)]))
        XCTAssertTrue(wave.snapshot.allSatisfy { $0 == .silence })
    }

    func testActualMinAndMaxNotAnInventedAnimation() throws {
        var wave = WaveformEnvelope(capacity: 4)
        let samples: [Float] = (0..<20).map { $0.isMultiple(of: 2) ? -0.4 : 0.7 }
        try wave.append(pcm([samples]))
        XCTAssertEqual(wave.snapshot, [.silence, .silence, .silence, .init(minimum: -0.4, maximum: 0.7)])
    }

    func testOppositePhaseStereoDoesNotCancelVisualization() throws {
        for interleaved in [false, true] {
            var wave = WaveformEnvelope(capacity: 4)
            try wave.append(pcm([[Float](repeating: 0.8, count: 20), [Float](repeating: -0.8, count: 20)], interleaved: interleaved))
            XCTAssertEqual(wave.snapshot.last, .init(minimum: -0.8, maximum: 0.8))
        }
    }

    func testPartialBinsSpanAudioCallbacks() throws {
        var wave = WaveformEnvelope(capacity: 4)
        try wave.append(pcm([[Float](repeating: 0.2, count: 10)]))
        try wave.append(pcm([[Float](repeating: -0.6, count: 10)]))
        XCTAssertEqual(wave.snapshot, [.silence, .silence, .silence, .init(minimum: -0.6, maximum: 0.2)])
    }

    func testHistoryHasFixedCapacity() throws {
        var wave = WaveformEnvelope(capacity: 3)
        for value in [Float(0.1), 0.2, 0.3, 0.4] {
            try wave.append(pcm([[Float](repeating: value, count: 20)]))
        }
        XCTAssertEqual(wave.snapshot, [Float(0.2), 0.3, 0.4].map { .init(minimum: $0, maximum: $0) })
    }

    func testTimestampGapBecomesFlatWaveform() throws {
        var wave = WaveformEnvelope(capacity: 4)
        try wave.append(pcm([[Float](repeating: 0.5, count: 20)]), timestamp: 100)
        try wave.append(pcm([[Float](repeating: 0.3, count: 20)]), timestamp: 100.06)
        XCTAssertEqual(wave.snapshot, [.init(minimum: 0.5, maximum: 0.5), .silence, .silence, .init(minimum: 0.3, maximum: 0.3)])
    }

    func testLongGapDoesNotRetainOldSoundOrGrowMemory() throws {
        var wave = WaveformEnvelope(capacity: 4)
        try wave.append(pcm([[Float](repeating: 0.5, count: 20)]), timestamp: 0)
        try wave.append(pcm([[Float](repeating: 0.3, count: 20)]), timestamp: 1e100)
        XCTAssertEqual(wave.snapshot, [.silence, .silence, .silence, .init(minimum: 0.3, maximum: 0.3)])
    }

    func testBackwardsTimestampStartsANewView() throws {
        var wave = WaveformEnvelope(capacity: 4)
        try wave.append(pcm([[Float](repeating: 0.5, count: 20)]), timestamp: 10)
        try wave.append(pcm([[Float](repeating: 0.3, count: 20)]), timestamp: 9)
        XCTAssertEqual(wave.snapshot.first, .silence)
        XCTAssertEqual(wave.snapshot.last, .init(minimum: 0.3, maximum: 0.3))
    }

    func testSampleRateChangeResetsTheTimeScale() throws {
        var wave = WaveformEnvelope(capacity: 4)
        try wave.append(pcm([[Float](repeating: 0.5, count: 20)]))
        try wave.append(pcm([[Float](repeating: 0.3, count: 40)], rate: 2000))
        XCTAssertEqual(wave.snapshot, [.silence, .silence, .silence, .init(minimum: 0.3, maximum: 0.3)])
    }

    func testVisualizationReadsWithoutModifyingSamples() throws {
        var wave = WaveformEnvelope(capacity: 2)
        let samples = pcm([[.nan, .infinity, -.infinity, -2, 2]])
        try wave.append(samples)
        XCTAssertEqual(wave.snapshot.last, .init(minimum: -1, maximum: 1))
        XCTAssertTrue(samples.floatChannelData![0][0].isNaN)
        XCTAssertEqual(samples.floatChannelData![0][3], -2)
    }

    func testGainAndMuteAreReflectedFromProcessedPCM() throws {
        let sample = pcm([[Float](repeating: 0.8, count: 20)])
        try AudioProcessor.process(sample, gain: 0.5, muted: false)
        var wave = WaveformEnvelope(capacity: 2)
        try wave.append(sample)
        XCTAssertEqual(wave.snapshot.last, .init(minimum: 0.4, maximum: 0.4))
        try AudioProcessor.process(sample, gain: 1, muted: true)
        try wave.append(sample)
        XCTAssertEqual(wave.snapshot.last, .silence)
    }

    func testIntegerPCMIsExplicitlyRejected() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false)!
        let sample = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 20)!
        sample.frameLength = 20
        var wave = WaveformEnvelope()
        XCTAssertThrowsError(try wave.append(sample))
    }
}

import AVFoundation
import CoreMedia
import XCTest
@testable import AudioCore

final class AudioCoreTests: XCTestCase {
    private func buffer(_ channels: [[Float]], interleaved: Bool = false, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: AVAudioChannelCount(channels.count), interleaved: interleaved)!
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        result.frameLength = result.frameCapacity
        for channel in channels.indices {
            for frame in channels[channel].indices {
                if interleaved {
                    result.floatChannelData![0][frame * channels.count + channel] = channels[channel][frame]
                } else {
                    result.floatChannelData![channel][frame] = channels[channel][frame]
                }
            }
        }
        return result
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AudioLoom-test-\(UUID().uuidString).wav")
    }

    func testPlanarGainAndIndependentChannelMeters() throws {
        let pcm = buffer([[0.2, -0.5], [0.1, -0.25]])
        let reading = try AudioProcessor.process(pcm, gain: 0.5, muted: false)
        XCTAssertEqual(pcm.floatChannelData![0][0], 0.1, accuracy: 0.00001)
        XCTAssertEqual(pcm.floatChannelData![0][1], -0.25, accuracy: 0.00001)
        XCTAssertEqual(reading.peaks, [0.25, 0.125])
        XCTAssertFalse(reading.clipped)
    }

    func testInterleavedGain() throws {
        let pcm = buffer([[0.2, -0.4], [0.3, -0.1]], interleaved: true)
        let reading = try AudioProcessor.process(pcm, gain: 2, muted: false)
        XCTAssertEqual(pcm.floatChannelData![0][0], 0.4, accuracy: 0.00001)
        XCTAssertEqual(pcm.floatChannelData![0][1], 0.6, accuracy: 0.00001)
        XCTAssertEqual(pcm.floatChannelData![0][2], -0.8, accuracy: 0.00001)
        XCTAssertEqual(pcm.floatChannelData![0][3], -0.2, accuracy: 0.00001)
        XCTAssertEqual(reading.peaks[0], 0.8, accuracy: 0.00001)
        XCTAssertEqual(reading.peaks[1], 0.6, accuracy: 0.00001)
    }

    func testMuteAndNonFiniteSamples() throws {
        let pcm = buffer([[0.5, -.infinity, .nan], [0.3, .infinity, -0.7]])
        let reading = try AudioProcessor.process(pcm, gain: 2, muted: true)
        XCTAssertEqual(reading.peaks, [0, 0])
        for channel in 0..<2 {
            for frame in 0..<3 { XCTAssertEqual(pcm.floatChannelData![channel][frame], 0) }
        }
    }

    func testClippingProtectsBothPolarities() throws {
        let pcm = buffer([[0.8, -0.7]])
        let reading = try AudioProcessor.process(pcm, gain: 2, muted: false)
        XCTAssertEqual(pcm.floatChannelData![0][0], 1)
        XCTAssertEqual(pcm.floatChannelData![0][1], -1)
        XCTAssertTrue(reading.clipped)
    }

    func testInvalidGainDoesNotWriteNaN() throws {
        let pcm = buffer([[0.8, -0.7]])
        let reading = try AudioProcessor.process(pcm, gain: .nan, muted: false)
        XCTAssertEqual(reading.peaks, [0])
    }

    func testSystemSampleIsCopiedNotMutated() throws {
        let pcm = buffer([[0.25, -0.5], [0.1, 0.2]])
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: 2, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample), noErr)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sample!,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(sample!), noErr)
        let copy = try AudioProcessor.copyPCM(from: sample!)
        try AudioProcessor.process(copy, gain: 2, muted: false)
        let original = try AudioProcessor.copyPCM(from: sample!)
        XCTAssertEqual(original.floatChannelData![0][0], 0.25)
        XCTAssertEqual(copy.floatChannelData![0][0], 0.5)
        XCTAssertEqual(copy.floatChannelData![1][1], 0.4, accuracy: 0.00001)
    }

    func testWAVRoundTripAndHeaderFinalization() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try WAVRecorder(url: url)
        let pcm = buffer([[0.1, 0.2, 0.3], [-0.1, -0.2, -0.3]])
        try recorder.append(pcm)
        XCTAssertEqual(recorder.finish(), url)
        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(reader.length, 3)
        XCTAssertEqual(reader.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(reader.fileFormat.channelCount, 2)
        let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 3)!
        try reader.read(into: decoded)
        XCTAssertEqual(decoded.floatChannelData![0][2], 0.3, accuracy: 0.00001)
        XCTAssertEqual(decoded.floatChannelData![1][2], -0.3, accuracy: 0.00001)
        XCTAssertThrowsError(try recorder.append(pcm))
    }

    func testInterleavedWAVRoundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try WAVRecorder(url: url)
        try recorder.append(buffer([[0.1, 0.2], [-0.1, -0.2]], interleaved: true))
        recorder.finish()
        let reader = try AVAudioFile(forReading: url)
        let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 2)!
        try reader.read(into: decoded)
        XCTAssertEqual(decoded.floatChannelData![1][1], -0.2, accuracy: 0.00001)
    }

    func testOneSecondSyntheticSineThroughProcessingAndFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.4 }
        let pcm = buffer([samples, samples])
        let reading = try AudioProcessor.process(pcm, gain: 0.5, muted: false)
        XCTAssertEqual(reading.peaks[0], 0.2, accuracy: 0.0001)
        let recorder = try WAVRecorder(url: url)
        try recorder.append(pcm, timestamp: 10)
        XCTAssertEqual(recorder.duration, 1, accuracy: 0.000001)
        recorder.finish()
        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(reader.length, 48_000)
        let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 48_000)!
        try reader.read(into: decoded)
        let rms = sqrt((0..<48_000).reduce(0.0) { $0 + pow(Double(decoded.floatChannelData![0][$1]), 2) } / 48_000)
        XCTAssertEqual(rms, 0.2 / sqrt(2), accuracy: 0.00001)
    }

    func testTimestampGapBecomesSilence() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try WAVRecorder(url: url)
        try recorder.append(buffer([[0.5, 0.5]]), timestamp: 100)
        try recorder.append(buffer([[0.25, 0.25]]), timestamp: 100 + 6.0 / 48_000)
        XCTAssertEqual(recorder.frameCount, 8)
        recorder.finish()
        let reader = try AVAudioFile(forReading: url)
        let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8)!
        try reader.read(into: decoded)
        for frame in 2..<6 { XCTAssertEqual(decoded.floatChannelData![0][frame], 0) }
        XCTAssertEqual(decoded.floatChannelData![0][6], 0.25)
    }

    func testEmptyRecordingDoesNotLeaveFile() throws {
        let url = temporaryURL()
        let recorder = try WAVRecorder(url: url)
        XCTAssertNil(recorder.finish())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExistingFileIsNeverTruncated() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("keep this file".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try WAVRecorder(url: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testFormatChangePreservesFirstSegment() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try WAVRecorder(url: url)
        try recorder.append(buffer([[0.2, 0.3]]))
        XCTAssertThrowsError(try recorder.append(buffer([[0.1]], sampleRate: 44_100)))
        recorder.finish()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 2)
    }

    func testSizeLimitPreservesValidFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try WAVRecorder(url: url, maxDataBytes: 16)
        try recorder.append(buffer([[0.1, 0.2]]))
        XCTAssertThrowsError(try recorder.append(buffer([[0.1, 0.2, 0.3]])))
        recorder.finish()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 2)
    }

    func testBackwardsTimestampStopsInsteadOfSplicingAudio() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try WAVRecorder(url: url)
        try recorder.append(buffer([[Float](repeating: 0.1, count: 20)]), timestamp: 100)
        XCTAssertThrowsError(try recorder.append(buffer([[0.1]]), timestamp: 100))
        recorder.finish()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 20)
    }
}

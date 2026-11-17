import AVFoundation
import XCTest
@testable import AudioCore

final class RecordingFormatTests: XCTestCase {
    private func signal(frames: Int = 48_000, interleaved: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = pcm.frameCapacity
        for frame in 0..<frames {
            let left = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.4
            let right = Float(sin(Double(frame) * 2 * .pi * 660 / 48_000)) * 0.2
            if interleaved {
                pcm.floatChannelData![0][frame * 2] = left
                pcm.floatChannelData![0][frame * 2 + 1] = right
            } else {
                pcm.floatChannelData![0][frame] = left
                pcm.floatChannelData![1][frame] = right
            }
        }
        return pcm
    }

    private func temporaryURL(_ format: RecordingFormat) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AudioLoom-format-\(UUID()).\(format.fileExtension)")
    }

    private func verify(_ format: RecordingFormat, interleaved: Bool = false) throws {
        let url = temporaryURL(format)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileRecorder(url: url, outputFormat: format)
        let original = signal(interleaved: interleaved)
        try writer.append(original)
        XCTAssertEqual(writer.finish(), url)
        XCTAssertNil(writer.finishError)
        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(reader.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(reader.fileFormat.channelCount, 2)
        let expectedCodec = format == .m4a ? kAudioFormatMPEG4AAC : format == .mp3 ? kAudioFormatMPEGLayer3 : kAudioFormatLinearPCM
        let compressed = format == .m4a || format == .mp3
        XCTAssertEqual(reader.fileFormat.streamDescription.pointee.mFormatID, expectedCodec)
        XCTAssertEqual(Double(reader.length), 48_000, accuracy: compressed ? 2304 : 0)
        let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(reader.length))!
        try reader.read(into: decoded)
        // Avoid encoder priming/padding in this amplitude check, but verify duration above.
        let start = 4096
        let end = min(Int(decoded.frameLength), 44_000)
        XCTAssertGreaterThan(end, start)
        for channel in 0..<2 {
            let samples = decoded.floatChannelData![channel]
            let rms = sqrt((start..<end).reduce(0.0) { $0 + pow(Double(samples[$1]), 2) } / Double(end - start))
            XCTAssertEqual(rms, (channel == 0 ? 0.4 : 0.2) / sqrt(2), accuracy: compressed ? 0.015 : 0.001)
        }
        if format == .wav {
            XCTAssertEqual(reader.fileFormat.streamDescription.pointee.mBitsPerChannel, 32)
        } else if format == .aiff {
            XCTAssertEqual(reader.fileFormat.streamDescription.pointee.mBitsPerChannel, 24)
        }
    }

    func testWAVIsFloatPCMAndDecodesCorrectly() throws { try verify(.wav) }
    func testM4AIsAACAndDecodesCorrectly() throws { try verify(.m4a) }
    func testAIFFIs24BitPCMAndDecodesCorrectly() throws { try verify(.aiff) }
    func testInterleavedM4AInput() throws { try verify(.m4a, interleaved: true) }
    func testInterleavedAIFFInput() throws { try verify(.aiff, interleaved: true) }
    func testMP3IsRealMPEGLayer3AndDecodesCorrectly() throws { try verify(.mp3) }
    func testInterleavedMP3Input() throws { try verify(.mp3, interleaved: true) }

    func testMP3HeaderDeclares320Kbps48KHz() throws {
        let url = temporaryURL(.mp3)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileRecorder(url: url, outputFormat: .mp3)
        try writer.append(signal())
        writer.finish()
        XCTAssertNil(writer.finishError)
        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(bytes.count, 38_000)
        XCTAssertEqual(bytes[0], 0xFF)
        XCTAssertEqual(bytes[1] & 0xFE, 0xFA) // MPEG-1, Layer III (CRC flag may vary).
        XCTAssertEqual((bytes[2] >> 4) & 0x0F, 14) // MPEG-1 Layer III: 320 kbps.
        XCTAssertEqual((bytes[2] >> 2) & 0x03, 1)  // MPEG-1: 48 kHz.
    }

    func testMP3ManySmallBuffersFlushAndFinalizeOnce() throws {
        let url = temporaryURL(.mp3)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileRecorder(url: url, outputFormat: .mp3)
        let chunk = signal(frames: 480)
        for index in 0..<100 { try writer.append(chunk, timestamp: 10 + Double(index) * 0.01) }
        writer.finish()
        XCTAssertNil(writer.finishError)
        let original = try Data(contentsOf: url)
        XCTAssertEqual(writer.finish(), url)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(Double(try AVAudioFile(forReading: url).length), 48_000, accuracy: 2304)
        XCTAssertThrowsError(try writer.append(chunk))
    }

    func testShortMP3IsReadable() throws {
        let url = temporaryURL(.mp3)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileRecorder(url: url, outputFormat: .mp3)
        try writer.append(signal(frames: 4800))
        writer.finish()
        XCTAssertNil(writer.finishError)
        XCTAssertGreaterThan(try AVAudioFile(forReading: url).length, 0)
    }

    func testAllFormatsRefuseExistingFiles() throws {
        for format in RecordingFormat.allCases {
            let url = temporaryURL(format)
            defer { try? FileManager.default.removeItem(at: url) }
            let data = Data("do not change".utf8)
            try data.write(to: url)
            XCTAssertThrowsError(try AudioFileRecorder(url: url, outputFormat: format))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testAllFormatsRemoveOnlyEmptyOwnedFiles() throws {
        for format in RecordingFormat.allCases {
            let url = temporaryURL(format)
            let writer = try AudioFileRecorder(url: url, outputFormat: format)
            XCTAssertNil(writer.finish())
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testWrongExtensionIsRejectedBeforeCreatingAFile() throws {
        let url = temporaryURL(.wav)
        XCTAssertThrowsError(try AudioFileRecorder(url: url, outputFormat: .m4a))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testM4AFlushesManySmallBuffers() throws {
        let url = temporaryURL(.m4a)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileRecorder(url: url, outputFormat: .m4a)
        let chunk = signal(frames: 480)
        for index in 0..<100 {
            try writer.append(chunk, timestamp: 10 + Double(index) * 0.01)
        }
        XCTAssertEqual(writer.duration, 1, accuracy: 0.000001)
        writer.finish()
        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(reader.length), 48_000, accuracy: 2048)
    }

    func testM4AFlushesAShortFinalBuffer() throws {
        let url = temporaryURL(.m4a)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileRecorder(url: url, outputFormat: .m4a)
        try writer.append(signal(frames: 4800))
        writer.finish()
        XCTAssertGreaterThan(try AVAudioFile(forReading: url).length, 0)
    }

    func testFormatAliasesAndStoredValues() throws {
        XCTAssertTrue(RecordingFormat.wav.acceptsExtension("WAV"))
        XCTAssertTrue(RecordingFormat.aiff.acceptsExtension("aif"))
        XCTAssertFalse(RecordingFormat.m4a.acceptsExtension("mp3"))
        for format in RecordingFormat.allCases {
            XCTAssertEqual(RecordingFormat(rawValue: format.rawValue), format)
            XCTAssertEqual(try JSONDecoder().decode(RecordingFormat.self, from: JSONEncoder().encode(format)), format)
        }
    }
}

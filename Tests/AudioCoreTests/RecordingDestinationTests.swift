import Foundation
import XCTest
@testable import AudioCore

final class RecordingDestinationTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 0)
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioLoom-destination-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testUsesTheSystemDownloadsLocationWithoutCreatingAFile() throws {
        let expected = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        XCTAssertEqual(try RecordingDestination.downloadsDirectory(), expected)
        XCTAssertTrue(try RecordingDestination.downloadsDirectory().isFileURL)
    }

    func testTimestampAndAllFormatExtensions() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for format in RecordingFormat.allCases {
            let url = RecordingDestination.uniqueURL(in: folder, format: format, date: fixedDate, timeZone: utc)
            XCTAssertEqual(url.lastPathComponent, "声流_1970-01-01_00-00-00-000.\(format.fileExtension)")
            XCTAssertEqual(url.deletingLastPathComponent(), folder)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testExistingRecordingNameGetsASuffixAndIsNotChanged() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = RecordingDestination.uniqueURL(in: folder, format: .mp3, date: fixedDate, timeZone: utc)
        let original = Data("existing recording".utf8)
        try original.write(to: first)
        let next = RecordingDestination.uniqueURL(in: folder, format: .mp3, date: fixedDate, timeZone: utc)
        XCTAssertEqual(next.lastPathComponent, "声流_1970-01-01_00-00-00-000-2.mp3")
        XCTAssertEqual(try Data(contentsOf: first), original)
    }

    func testRepeatedReservationsAtTheSameTimeRemainUnique() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try RecordingDestination.createRecorder(in: folder, format: .wav, date: fixedDate, timeZone: utc)
        let second = try RecordingDestination.createRecorder(in: folder, format: .wav, date: fixedDate, timeZone: utc)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        first.finish()
        second.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testEveryFormatCanBeReservedWithoutAnAudioCapture() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for format in RecordingFormat.allCases {
            let recorder = try RecordingDestination.createRecorder(in: folder, format: format)
            XCTAssertEqual(recorder.outputFormat, format)
            XCTAssertEqual(recorder.url.pathExtension, format.fileExtension)
            XCTAssertEqual(recorder.frameCount, 0)
            XCTAssertNil(recorder.finish())
        }
    }

    func testMissingDirectoryCanBePrepared() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent("one/two", isDirectory: true)
        try RecordingDestination.prepareDirectory(nested)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testExistingFileIsNeverReplacedWithDirectory() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("not-a-folder")
        let original = Data("keep".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try RecordingDestination.prepareDirectory(file))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testNonFileDestinationIsRejected() {
        XCTAssertThrowsError(try RecordingDestination.prepareDirectory(URL(string: "https://example.invalid/recordings")!))
    }

    func testDanglingSymlinkIsTreatedAsOccupied() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = RecordingDestination.uniqueURL(in: folder, format: .wav, date: fixedDate, timeZone: utc)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: folder.appendingPathComponent("missing"))
        let recorder = try RecordingDestination.createRecorder(in: folder, format: .wav, date: fixedDate, timeZone: utc)
        XCTAssertNotEqual(recorder.url, first)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: first.path))
        recorder.finish()
    }

    func testConcurrentReservationsDoNotOverwriteOrDeleteEachOther() throws {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var recorders: [AudioFileRecorder] = []
            var failures: [String] = []
            func add(_ result: Result<AudioFileRecorder, Error>) {
                lock.lock()
                defer { lock.unlock() }
                switch result {
                case .success(let recorder): recorders.append(recorder)
                case .failure(let error): failures.append(error.localizedDescription)
                }
            }
        }
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = fixedDate
        let zone = utc
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            results.add(Result { try RecordingDestination.createRecorder(in: folder, format: .wav, date: date, timeZone: zone) })
        }
        XCTAssertEqual(results.failures, [])
        XCTAssertEqual(results.recorders.count, 12)
        XCTAssertEqual(Set(results.recorders.map(\.url)).count, 12)
        for recorder in results.recorders {
            XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.url.path))
            recorder.finish()
        }
    }
}

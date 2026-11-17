import Foundation
import XCTest
@testable import AudioCore

final class RecordingPresentationTests: XCTestCase {
    func testIdleIsCompactAndNotRecording() {
        let state = RecordingIndicator.make(phase: .idle)
        XCTAssertEqual(state.title, "")
        XCTAssertEqual(state.symbol, "waveform")
        XCTAssertEqual(state.tone, .neutral)
        XCTAssertFalse(state.usesVariableWidth)
    }

    func testRecordingShowsTimeAndRedIndicator() {
        let state = RecordingIndicator.make(phase: .recording, duration: 73.8, source: "音乐", format: "MP3")
        XCTAssertEqual(state.title, "01:13")
        XCTAssertEqual(state.tone, .recording)
        XCTAssertTrue(state.usesVariableWidth)
        XCTAssertTrue(state.tooltip.contains("音乐"))
        XCTAssertTrue(state.tooltip.contains("MP3"))
    }

    func testHoursAreNotLost() {
        XCTAssertEqual(RecordingIndicator.clock(3661), "01:01:01")
    }

    func testMuteIsVisibleOnlyWhenRecording() {
        let active = RecordingIndicator.make(phase: .recording, duration: 42, muted: true)
        XCTAssertEqual(active.title, "00:42 静音")
        XCTAssertTrue(active.tooltip.contains("写入静音"))
        XCTAssertTrue(RecordingIndicator.make(phase: .idle, muted: true).title.isEmpty)
    }

    func testWaitingForFirstAudioIsExplained() {
        XCTAssertTrue(RecordingIndicator.make(phase: .recording).tooltip.contains("等待音频"))
        XCTAssertFalse(RecordingIndicator.make(phase: .recording, duration: 1).tooltip.contains("等待音频"))
    }

    func testSavingIsNotShownAsRecording() {
        let state = RecordingIndicator.make(phase: .saving)
        XCTAssertEqual(state.title, "保存")
        XCTAssertEqual(state.tone, .neutral)
        XCTAssertTrue(state.tooltip.contains("尚未完成"))
    }

    func testConnectingIsDistinct() {
        XCTAssertEqual(RecordingIndicator.make(phase: .connecting).title, "连接")
    }

    func testFailureHasAnExplanationWithoutAHugeTooltip() {
        let state = RecordingIndicator.make(phase: .attention, error: String(repeating: "错误", count: 200))
        XCTAssertEqual(state.tone, .warning)
        XCTAssertTrue(state.tooltip.contains("录音未完成"))
        XCTAssertLessThan(state.tooltip.count, 200)
        XCTAssertTrue(state.title.isEmpty)
    }

    func testClockHandlesInvalidValuesSafely() {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(RecordingIndicator.clock(value), "00:00")
        }
        XCTAssertEqual(RecordingIndicator.clock(.greatestFiniteMagnitude), "99:59:59")
    }

    func testUpdatesAreStableWithinTheSameSecond() {
        let a = RecordingIndicator.make(phase: .recording, duration: 73.1)
        let b = RecordingIndicator.make(phase: .recording, duration: 73.9)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, RecordingIndicator.make(phase: .recording, duration: 74))
    }

    func testSuccessfulExplicitStopRevealsTheExactFile() {
        let url = URL(fileURLWithPath: "/tmp/example.mp3")
        XCTAssertEqual(RecordingCompletionPresentation.revealURL(savedURL: url, failed: false, requested: true), url)
    }

    func testFailedOrEmptySaveDoesNotReveal() {
        XCTAssertNil(RecordingCompletionPresentation.revealURL(savedURL: URL(fileURLWithPath: "/tmp/partial.mp3"), failed: true, requested: true))
        XCTAssertNil(RecordingCompletionPresentation.revealURL(savedURL: nil, failed: false, requested: true))
    }

    func testQuitOrAutomaticFailureDoesNotOpenFinder() {
        XCTAssertNil(RecordingCompletionPresentation.revealURL(savedURL: URL(fileURLWithPath: "/tmp/example.mp3"), failed: false, requested: false))
    }

    func testNonFileURLsAreNotLaunched() {
        XCTAssertNil(RecordingCompletionPresentation.revealURL(savedURL: URL(string: "https://example.invalid/audio.mp3"), failed: false, requested: true))
    }
}

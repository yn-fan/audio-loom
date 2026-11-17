import XCTest
@testable import OutputControl

final class OutputControlTests: XCTestCase {
    private func reply(current: UInt16 = 50, maximum: UInt16 = 100, result: UInt8 = 0, feature: UInt8 = 0x62) -> [UInt8] {
        let body: [UInt8] = [0x6E, 0x88, 0x02, result, feature, 0,
                             UInt8(maximum >> 8), UInt8(maximum & 255), UInt8(current >> 8), UInt8(current & 255)]
        return body + [body.reduce(UInt8(0x50), ^), 0]
    }

    func testReadQueryDoesNotUseSetVCP() {
        XCTAssertEqual(DDCVolumeProtocol.query, [0x82, 0x01, 0x62, 0xDE])
    }
    func testSetVolumeFrameAndChecksum() throws {
        XCTAssertEqual(try DDCVolumeProtocol.setVolume(50, maximum: 100), [0x84, 0x03, 0x62, 0, 0x32, 0xE8])
    }
    func testZeroVolumeKeepsRequiredZeroBytes() throws {
        XCTAssertEqual(try DDCVolumeProtocol.setVolume(0, maximum: 100), [0x84, 0x03, 0x62, 0, 0, 0xDA])
    }
    func testFull16BitEncoding() throws {
        let command = try DDCVolumeProtocol.setVolume(0x1234, maximum: 65535)
        XCTAssertEqual(Array(command[3...4]), [0x12, 0x34])
        XCTAssertEqual(command.reduce(UInt8(0x6E ^ 0x51), ^), 0)
    }
    func testExampleDisplayReply() throws {
        let value = try DDCVolumeProtocol.decode([0x6E, 0x88, 2, 0, 0x62, 0, 0, 0x64, 0, 0x32, 0x80, 0])
        XCTAssertEqual(value.current, 50)
        XCTAssertEqual(value.maximum, 100)
        XCTAssertEqual(value.fraction, 0.5)
    }
    func testDifferentHardwareRange() throws {
        let value = try DDCVolumeProtocol.decode(reply(current: 128, maximum: 255))
        XCTAssertEqual(value.fraction, 128.0 / 255)
        XCTAssertEqual(try DDCVolumeProtocol.rawValue(fraction: 0.5, maximum: 255), 128)
    }
    func testChecksumFailureIsNotTreatedAsVolume() {
        var bytes = reply()
        bytes[10] ^= 0x01
        XCTAssertThrowsError(try DDCVolumeProtocol.decode(bytes))
    }
    func testShortReplyRejected() {
        XCTAssertThrowsError(try DDCVolumeProtocol.decode([0, 0, 0]))
    }
    func testWrongFeatureRejected() {
        XCTAssertThrowsError(try DDCVolumeProtocol.decode(reply(feature: 0x10)))
    }
    func testWrongReplyCommandRejected() {
        var bytes = reply()
        bytes[2] = 0x03
        XCTAssertThrowsError(try DDCVolumeProtocol.decode(bytes))
    }
    func testUnsupportedFeatureIsExplicit() {
        XCTAssertThrowsError(try DDCVolumeProtocol.decode(reply(result: 1))) {
            XCTAssertEqual($0 as? OutputControlError, .unsupportedVCP)
        }
    }
    func testInvalidHardwareRangeRejected() {
        XCTAssertThrowsError(try DDCVolumeProtocol.decode(reply(current: 0, maximum: 0)))
        XCTAssertThrowsError(try DDCVolumeProtocol.decode(reply(current: 101, maximum: 100)))
    }
    func testInvalidUserValuesRejected() {
        for value in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertThrowsError(try DDCVolumeProtocol.rawValue(fraction: value, maximum: 100))
        }
    }
    func testBoundaryValuesAndRounding() throws {
        XCTAssertEqual(try DDCVolumeProtocol.rawValue(fraction: 0, maximum: 100), 0)
        XCTAssertEqual(try DDCVolumeProtocol.rawValue(fraction: 1, maximum: 100), 100)
        XCTAssertEqual(try DDCVolumeProtocol.rawValue(fraction: 0.456, maximum: 100), 46)
        XCTAssertEqual(try DDCVolumeProtocol.rawValue(fraction: 1, maximum: 65535), 65535)
    }
    func testInvalidRawWritesRejected() {
        XCTAssertThrowsError(try DDCVolumeProtocol.setVolume(101, maximum: 100))
        XCTAssertThrowsError(try DDCVolumeProtocol.setVolume(0, maximum: 0))
    }
    func testUniqueNamedDisplayMatches() throws {
        let screen = ExternalDisplay(id: 2, name: "Example Display")
        XCTAssertEqual(try VolumeValidation.matchingDisplay(outputName: "example display ", displays: [screen], serviceCount: 1), screen)
    }
    func testWrongDisplayNameRejected() {
        XCTAssertThrowsError(try VolumeValidation.matchingDisplay(outputName: "Other", displays: [.init(id: 2, name: "Example Display")], serviceCount: 1))
    }
    func testMultipleDisplaysRejected() {
        XCTAssertThrowsError(try VolumeValidation.matchingDisplay(outputName: "Example Display", displays: [
            .init(id: 2, name: "Example Display"), .init(id: 3, name: "Example Display")
        ], serviceCount: 2))
    }
    func testAmbiguousOrMissingServiceRejected() {
        for count in [0, 2] {
            XCTAssertThrowsError(try VolumeValidation.matchingDisplay(outputName: "Example Display", displays: [.init(id: 2, name: "Example Display")], serviceCount: count))
        }
        XCTAssertThrowsError(try VolumeValidation.matchingDisplay(outputName: "Example Display", displays: [], serviceCount: 1))
    }
    func testDeviceSwitchCancelsOldIntent() throws {
        try VolumeValidation.requireSameDevice(expected: "device1", actual: "device1")
        XCTAssertThrowsError(try VolumeValidation.requireSameDevice(expected: "device1", actual: "device2")) {
            XCTAssertEqual($0 as? OutputControlError, .changedDevice)
        }
    }
    func testReadOnlyServiceCannotWriteEvenBeforeDeviceLookup() {
        let service = OutputVolumeService(allowsWrites: false)
        XCTAssertThrowsError(try service.setVolume(0.1, expectedToken: "", displays: [])) {
            XCTAssertEqual($0 as? OutputControlError, .readOnly)
        }
    }
}

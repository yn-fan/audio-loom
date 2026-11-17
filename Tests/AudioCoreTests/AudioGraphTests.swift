import AVFoundation
import XCTest
@testable import AudioCore

final class AudioGraphTests: XCTestCase {
    private func pcm(_ left: Float = 0.8, _ right: Float = 0.2, interleaved: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        result.frameLength = 1
        result.floatChannelData![0][0] = left
        if interleaved { result.floatChannelData![0][1] = right }
        else { result.floatChannelData![1][0] = right }
        return result
    }

    func testDefaultRouteExecutesConnectedGain() throws {
        var graph = AudioGraph.standard()
        graph.nodes[1].gain = 0.5
        let buffer = pcm()
        let result = try graph.compile().process(buffer)
        XCTAssertEqual(result.peaks[0], 0.4, accuracy: 0.00001)
        XCTAssertEqual(result.peaks[1], 0.1, accuracy: 0.00001)
    }

    func testDisconnectCannotCompileForRecording() throws {
        var graph = AudioGraph.standard()
        graph.disconnect(graph.connections[0])
        try graph.validateStructure()
        XCTAssertThrowsError(try graph.compile()) { XCTAssertEqual($0 as? RoutingError, .disconnected) }
    }

    func testDirectCableActuallySkipsVolumeNode() throws {
        var graph = AudioGraph.standard()
        graph.nodes[1].gain = 0
        try graph.connect(from: graph.nodes[0].id, to: graph.nodes[2].id)
        let plan = try graph.compile()
        XCTAssertEqual(plan.nodes.map(\.kind), [.source, .recorder])
        let result = try plan.process(pcm())
        XCTAssertEqual(result.peaks[0], 0.8, accuracy: 0.00001)
    }

    func testCableOrderNotArrayOrderDeterminesProcessing() throws {
        let source = AudioNode(kind: .source)
        let loud = AudioNode(kind: .gain, gain: 2)
        let soft = AudioNode(kind: .gain, gain: 0.5)
        let recorder = AudioNode(kind: .recorder)
        var graph = AudioGraph(nodes: [recorder, soft, source, loud], connections: [
            .init(from: source.id, to: loud.id), .init(from: loud.id, to: soft.id),
            .init(from: soft.id, to: recorder.id)
        ])
        let first = try graph.compile().process(pcm())
        XCTAssertEqual(first.peaks[0], 0.5, accuracy: 0.00001)
        XCTAssertTrue(first.clipped)
        graph.connections = [
            .init(from: source.id, to: soft.id), .init(from: soft.id, to: loud.id),
            .init(from: loud.id, to: recorder.id)
        ]
        let second = try graph.compile().process(pcm())
        XCTAssertEqual(second.peaks[0], 0.8, accuracy: 0.00001)
        XCTAssertFalse(second.clipped)
    }

    func testBypassedGainIsNotExecuted() throws {
        var graph = AudioGraph.standard()
        graph.nodes[1].gain = 0
        graph.nodes[1].bypassed = true
        XCTAssertEqual(try graph.compile().process(pcm()).peaks[0], 0.8, accuracy: 0.00001)
    }

    func testOutputMuteAppliesEvenWithDirectConnection() throws {
        var graph = AudioGraph.standard()
        graph.nodes[2].muted = true
        try graph.connect(from: graph.nodes[0].id, to: graph.nodes[2].id)
        XCTAssertEqual(try graph.compile().process(pcm()).peaks, [0, 0])
    }

    func testMonoNodeProcessesBothLayouts() throws {
        for interleaved in [false, true] {
            var graph = AudioGraph.standard()
            let mono = try graph.addProcessor(.mono)
            try graph.connect(from: graph.nodes[1].id, to: mono)
            try graph.connect(from: mono, to: graph.nodes[2].id)
            let output = try graph.compile().process(pcm(interleaved: interleaved))
            XCTAssertEqual(output.peaks[0], 0.5, accuracy: 0.00001)
            XCTAssertEqual(output.peaks[1], 0.5, accuracy: 0.00001)
        }
    }

    func testSnapshotIsIndependentOfLaterKnobChanges() throws {
        var graph = AudioGraph.standard()
        let earlier = try graph.compile()
        graph.nodes[1].gain = 0
        XCTAssertEqual(try earlier.process(pcm()).peaks[0], 0.8, accuracy: 0.00001)
        XCTAssertEqual(try graph.compile().process(pcm()).peaks, [0, 0])
    }

    func testCycleIsRejectedAtomically() throws {
        var graph = AudioGraph.standard()
        let mono = try graph.addProcessor(.mono)
        let gain = graph.nodes[1].id
        try graph.connect(from: gain, to: mono)
        let before = graph
        XCTAssertThrowsError(try graph.connect(from: mono, to: gain)) { XCTAssertEqual($0 as? RoutingError, .cycle) }
        XCTAssertEqual(graph, before)
    }

    func testInvalidPortsAndSelfLinksAreRejected() throws {
        var graph = AudioGraph.standard()
        let before = graph
        XCTAssertThrowsError(try graph.connect(from: graph.nodes[0].id, to: graph.nodes[0].id))
        XCTAssertThrowsError(try graph.connect(from: graph.nodes[2].id, to: graph.nodes[1].id))
        XCTAssertThrowsError(try graph.connect(from: graph.nodes[1].id, to: graph.nodes[0].id))
        XCTAssertEqual(graph, before)
    }

    func testRemovingProcessorRemovesItsEdgesNotEndpointNodes() throws {
        var graph = AudioGraph.standard()
        graph.removeProcessor(graph.nodes[0].id)
        XCTAssertEqual(graph.nodes.count, 3)
        graph.removeProcessor(graph.nodes[1].id)
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(graph.connections.count, 0)
        XCTAssertThrowsError(try graph.compile())
    }

    func testGraphSettingsAndPositionsRoundTrip() throws {
        var graph = AudioGraph.standard()
        graph.nodes[1].gain = 0.35
        graph.nodes[1].x = 220
        graph.nodes[1].bypassed = true
        let restored = try JSONDecoder().decode(AudioGraph.self, from: JSONEncoder().encode(graph))
        XCTAssertEqual(graph, restored)
        try restored.validateStructure()
    }

    func testMalformedStoredGraphsAreRejected() throws {
        var graph = AudioGraph.standard()
        graph.nodes[1].gain = .nan
        XCTAssertThrowsError(try graph.compile())
        graph = .standard()
        graph.nodes[1].x = .infinity
        XCTAssertThrowsError(try graph.compile())
        graph = .standard()
        graph.nodes.append(graph.nodes[0])
        XCTAssertThrowsError(try graph.compile())
    }

    func testBranchingIsExplicitlyRejectedInThisVersion() throws {
        var graph = AudioGraph.standard()
        graph.connections.append(.init(from: graph.nodes[0].id, to: graph.nodes[2].id))
        XCTAssertThrowsError(try graph.compile())
    }

    func testUnconnectedModuleHasNoEffect() throws {
        var graph = AudioGraph.standard()
        let id = try graph.addProcessor(.gain)
        graph.nodes[graph.nodes.firstIndex { $0.id == id }!].gain = 0
        XCTAssertEqual(try graph.compile().process(pcm()).peaks[0], 0.8, accuracy: 0.00001)
    }

    func testNodeLimitIsEnforced() throws {
        var graph = AudioGraph.standard()
        for _ in 0..<9 { try graph.addProcessor(.gain) }
        XCTAssertEqual(graph.nodes.count, 12)
        XCTAssertThrowsError(try graph.addProcessor(.mono))
    }

    func testRoutedAudioIsWhatReachesWAV() throws {
        var graph = AudioGraph.standard()
        graph.nodes[1].gain = 0.5
        let buffer = pcm()
        try graph.compile().process(buffer)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioLoom-graph-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try WAVRecorder(url: url)
        try recorder.append(buffer)
        recorder.finish()
        let reader = try AVAudioFile(forReading: url)
        let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 1)!
        try reader.read(into: decoded)
        XCTAssertEqual(decoded.floatChannelData![0][0], 0.4, accuracy: 0.00001)
        XCTAssertEqual(decoded.floatChannelData![1][0], 0.1, accuracy: 0.00001)
    }
}

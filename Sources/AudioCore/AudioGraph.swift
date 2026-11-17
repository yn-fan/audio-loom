import AVFoundation
import Foundation

public enum NodeKind: String, Codable, Sendable, CaseIterable {
    case source, gain, mono, recorder
    public var title: String {
        switch self {
        case .source: return "音源"
        case .gain: return "音量"
        case .mono: return "单声道"
        case .recorder: return "录音"
        }
    }
    public var symbol: String {
        switch self {
        case .source: return "app"
        case .gain: return "speaker.wave.2"
        case .mono: return "waveform"
        case .recorder: return "record.circle"
        }
    }
    public var isProcessor: Bool { self == .gain || self == .mono }
}

public struct AudioNode: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: NodeKind
    public var gain: Float
    public var bypassed: Bool
    public var muted: Bool
    public var x: Double
    public var y: Double

    public init(id: UUID = UUID(), kind: NodeKind, gain: Float = 1,
                bypassed: Bool = false, muted: Bool = false, x: Double = 100, y: Double = 100) {
        self.id = id
        self.kind = kind
        self.gain = gain
        self.bypassed = bypassed
        self.muted = muted
        self.x = x
        self.y = y
    }
}

public struct AudioConnection: Identifiable, Codable, Equatable, Sendable {
    public let from: UUID
    public let to: UUID
    public var id: String { "\(from)-\(to)" }
    public init(from: UUID, to: UUID) { self.from = from; self.to = to }
}

public enum RoutingError: LocalizedError, Equatable {
    case invalidGraph, invalidPort, cycle, disconnected, tooManyNodes
    public var errorDescription: String? {
        switch self {
        case .invalidGraph: return "流程数据无效。请还原默认流程。"
        case .invalidPort: return "请从右侧输出端连接到另一个模块的左侧输入端。"
        case .cycle: return "不能连接成回路，以免产生音频反馈。"
        case .disconnected: return "音源还没有连到录音模块。"
        case .tooManyNodes: return "学习版最多支持 12 个模块。"
        }
    }
}

/// One source, one recorder, and an editable single signal path.
/// Disconnected nodes are valid editing states but are never executed.
public struct AudioGraph: Codable, Equatable, Sendable {
    public var nodes: [AudioNode]
    public var connections: [AudioConnection]

    public init(nodes: [AudioNode], connections: [AudioConnection]) {
        self.nodes = nodes
        self.connections = connections
    }

    public static func standard() -> AudioGraph {
        let source = AudioNode(kind: .source, x: 90, y: 112)
        let gain = AudioNode(kind: .gain, x: 300, y: 112)
        let recorder = AudioNode(kind: .recorder, x: 510, y: 112)
        return AudioGraph(nodes: [source, gain, recorder], connections: [
            AudioConnection(from: source.id, to: gain.id),
            AudioConnection(from: gain.id, to: recorder.id)
        ])
    }

    public func validateStructure() throws {
        guard nodes.count <= 12 else { throw RoutingError.tooManyNodes }
        guard nodes.filter({ $0.kind == .source }).count == 1,
              nodes.filter({ $0.kind == .recorder }).count == 1,
              Set(nodes.map(\.id)).count == nodes.count,
              Set(connections.map(\.id)).count == connections.count,
              nodes.allSatisfy({ $0.gain.isFinite && (0...2).contains($0.gain)
                  && $0.x.isFinite && $0.y.isFinite
                  && (0...2_000).contains($0.x) && (0...2_000).contains($0.y) }) else {
            throw RoutingError.invalidGraph
        }
        let lookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for edge in connections {
            guard let from = lookup[edge.from], let to = lookup[edge.to],
                  from.kind != .recorder, to.kind != .source, from.id != to.id,
                  connections.filter({ $0.from == edge.from }).count == 1,
                  connections.filter({ $0.to == edge.to }).count == 1 else { throw RoutingError.invalidPort }
        }
        // Check disconnected islands as well as the active source-to-recorder route.
        let outgoing = Dictionary(uniqueKeysWithValues: connections.map { ($0.from, $0.to) })
        for node in nodes {
            var visited = Set<UUID>()
            var cursor: UUID? = node.id
            while let current = cursor {
                guard visited.insert(current).inserted else { throw RoutingError.cycle }
                cursor = outgoing[current]
            }
        }
    }

    public func compile() throws -> RoutingPlan {
        try validateStructure()
        var path = [AudioNode]()
        var node = nodes.first { $0.kind == .source }!
        while true {
            path.append(node)
            if node.kind == .recorder { return RoutingPlan(nodes: path) }
            guard let edge = connections.first(where: { $0.from == node.id }),
                  let next = nodes.first(where: { $0.id == edge.to }) else { throw RoutingError.disconnected }
            node = next
        }
    }

    /// Connections replace the two involved port connections, not unrelated edges.
    /// Validation happens on a copy, so rejected cycles cannot damage the graph.
    public mutating func connect(from: UUID, to: UUID) throws {
        guard let source = nodes.first(where: { $0.id == from }),
              let target = nodes.first(where: { $0.id == to }),
              from != to, source.kind != .recorder, target.kind != .source else {
            throw RoutingError.invalidPort
        }
        var proposed = self
        proposed.connections.removeAll { $0.from == from || $0.to == to }
        proposed.connections.append(AudioConnection(from: from, to: to))
        try proposed.validateStructure()
        self = proposed
    }

    public mutating func disconnect(_ edge: AudioConnection) {
        connections.removeAll { $0 == edge }
    }

    public mutating func removeProcessor(_ id: UUID) {
        guard nodes.first(where: { $0.id == id })?.kind.isProcessor == true else { return }
        nodes.removeAll { $0.id == id }
        connections.removeAll { $0.from == id || $0.to == id }
    }

    @discardableResult
    public mutating func addProcessor(_ kind: NodeKind) throws -> UUID {
        guard kind.isProcessor else { throw RoutingError.invalidPort }
        guard nodes.count < 12 else { throw RoutingError.tooManyNodes }
        let index = nodes.filter { $0.kind.isProcessor }.count - 1
        let node = AudioNode(kind: kind, x: Double(90 + (max(0, index) % 3) * 210),
                             y: Double(226 + (max(0, index) / 3) * 110))
        nodes.append(node)
        return node.id
    }
}

/// A value snapshot exchanged on the audio queue, never a live mutable UI graph.
public struct RoutingPlan: Sendable {
    public let nodes: [AudioNode]
    public var description: String { nodes.map { $0.kind.title }.joined(separator: " → ") }

    @discardableResult
    public func process(_ buffer: AVAudioPCMBuffer) throws -> MeterReading {
        var clipped = false
        for node in nodes {
            switch node.kind {
            case .source: break
            case .gain:
                if !node.bypassed {
                    let meter = try AudioProcessor.process(buffer, gain: node.gain, muted: false)
                    clipped = clipped || meter.clipped
                }
            case .mono:
                if !node.bypassed { try mixToMono(buffer) }
            case .recorder:
                let meter = try AudioProcessor.process(buffer, gain: 1, muted: node.muted)
                return MeterReading(peaks: meter.peaks, clipped: clipped || meter.clipped)
            }
        }
        throw RoutingError.disconnected
    }

    private func mixToMono(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let data = buffer.floatChannelData else { throw AudioError.unsupportedFormat }
        let channels = Int(buffer.format.channelCount)
        guard channels > 1 else { return }
        for frame in 0..<Int(buffer.frameLength) {
            var sum = 0.0
            for channel in 0..<channels {
                let sample = buffer.format.isInterleaved ? data[0][frame * channels + channel] : data[channel][frame]
                sum += sample.isFinite ? Double(sample) : 0
            }
            let mono = Float(sum / Double(channels))
            for channel in 0..<channels {
                if buffer.format.isInterleaved { data[0][frame * channels + channel] = mono }
                else { data[channel][frame] = mono }
            }
        }
    }
}

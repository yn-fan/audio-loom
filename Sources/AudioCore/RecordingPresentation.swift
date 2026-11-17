import Foundation

public enum RecordingIndicatorPhase: Equatable, Sendable { case idle, connecting, recording, saving, attention }
public enum RecordingIndicatorTone: Equatable, Sendable { case neutral, recording, warning }

public struct RecordingIndicator: Equatable, Sendable {
    public let title: String
    public let symbol: String
    public let tooltip: String
    public let tone: RecordingIndicatorTone
    public var usesVariableWidth: Bool { !title.isEmpty }

    public static func clock(_ duration: TimeInterval) -> String {
        let value = duration.isFinite ? min(359_999, max(0, duration)) : 0
        let seconds = Int(value)
        if seconds >= 3600 {
            return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    public static func make(phase: RecordingIndicatorPhase, duration: TimeInterval = 0,
                            muted: Bool = false, source: String = "", format: String = "",
                            error: String = "") -> RecordingIndicator {
        switch phase {
        case .idle:
            return .init(title: "", symbol: "waveform", tooltip: "声流 · 点击打开", tone: .neutral)
        case .connecting:
            return .init(title: "连接", symbol: "ellipsis.circle", tooltip: "声流 · 正在连接音源", tone: .neutral)
        case .saving:
            return .init(title: "保存", symbol: "square.and.arrow.down", tooltip: "声流 · 正在保存，尚未完成", tone: .neutral)
        case .attention:
            return .init(title: "", symbol: "exclamationmark.triangle.fill",
                         tooltip: "声流 · 录音未完成\n\(String(error.prefix(160)))", tone: .warning)
        case .recording:
            let time = clock(duration)
            let extra = muted ? "\n录音文件正在写入静音" : duration <= 0 ? "\n等待音频数据" : ""
            return .init(title: time + (muted ? " 静音" : ""), symbol: "circle.fill",
                         tooltip: "声流 · 正在录音\n\(source) · \(format) · 已写入 \(time)\(extra)\n点击打开控制面板",
                         tone: .recording)
        }
    }
}

public enum RecordingCompletionPresentation {
    /// Only a successful user-requested stop reveals the finished local file.
    /// Error/empty/interrupted sessions and quitting do not unexpectedly open Finder.
    public static func revealURL(savedURL: URL?, failed: Bool, requested: Bool) -> URL? {
        guard requested, !failed, let savedURL, savedURL.isFileURL else { return nil }
        return savedURL
    }
}

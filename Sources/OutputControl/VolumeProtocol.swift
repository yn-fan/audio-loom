import Foundation

public enum OutputControlError: LocalizedError, Equatable {
    case noDevice, unsupported, ambiguousDisplay, unavailable, invalidReply
    case unsupportedVCP, changedDevice, invalidVolume, notApplied, readOnly
    case systemFailure(Int32)
    public var errorDescription: String? {
        switch self {
        case .noDevice: return "没有找到当前外放设备。"
        case .unsupported: return "当前设备没有开放音量控制接口。"
        case .ambiguousDisplay: return "无法唯一对应外放显示器；为避免调错设备，暂不启用硬件控制。"
        case .unavailable: return "显示器控制接口不可用。可检查显示器菜单中的 DDC/CI 设置。"
        case .invalidReply: return "显示器没有返回有效音量。请检查 DDC/CI 或连接方式后重试。"
        case .unsupportedVCP: return "显示器不支持通过 DDC/CI 控制扬声器音量。"
        case .changedDevice: return "外放设备已切换，请在新设备显示后重新调整。"
        case .invalidVolume: return "音量必须在 0% 到 100% 之间。"
        case .notApplied: return "设备没有确认新的音量，已保留读取到的数值。"
        case .readOnly: return "只读检查模式不会改变硬件音量。"
        case .systemFailure(let code): return "无法控制当前外放设备（\(code)）。"
        }
    }
}

public struct ExternalDisplay: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public init(id: UInt32, name: String) { self.id = id; self.name = name }
}

public enum OutputMethod: String, Sendable {
    case system, displayHardware
    public var label: String { self == .system ? "系统外放" : "显示器硬件" }
}

public struct OutputVolumeSnapshot: Equatable, Sendable {
    public let token: String
    public let deviceName: String
    public let method: OutputMethod
    public let fraction: Double
    public init(token: String, deviceName: String, method: OutputMethod, fraction: Double) {
        self.token = token; self.deviceName = deviceName; self.method = method; self.fraction = fraction
    }
}

public struct OutputInspection: Sendable {
    public let deviceName: String
    public let volume: OutputVolumeSnapshot?
    public let explanation: String?
    public init(deviceName: String, volume: OutputVolumeSnapshot?, explanation: String? = nil) {
        self.deviceName = deviceName; self.volume = volume; self.explanation = explanation
    }
}

public enum VolumeValidation {
    public static func fraction(_ value: Double) throws -> Double {
        guard value.isFinite, (0...1).contains(value) else { throw OutputControlError.invalidVolume }
        return value
    }
    public static func matchingDisplay(outputName: String, displays: [ExternalDisplay], serviceCount: Int) throws -> ExternalDisplay {
        guard displays.count == 1, serviceCount == 1,
              displays[0].name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(outputName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else {
            throw OutputControlError.ambiguousDisplay
        }
        return displays[0]
    }
    public static func requireSameDevice(expected: String, actual: String) throws {
        guard expected == actual else { throw OutputControlError.changedDevice }
    }
}

/// DDC/CI audio volume (VCP 0x62). This module never captures or processes audio.
/// IOAV function declarations and packet framing were cross-checked against the
/// MIT-licensed m1ddc project; see THIRD_PARTY_NOTICES.md.
public enum DDCVolumeProtocol {
    public struct Reading: Equatable, Sendable {
        public let current: UInt16
        public let maximum: UInt16
        public var fraction: Double { Double(current) / Double(maximum) }
    }

    public static var query: [UInt8] {
        let body: [UInt8] = [0x82, 0x01, 0x62] // Get-VCP, never Set-VCP.
        return body + [body.reduce(UInt8(0x6E ^ 0x51), ^)]
    }

    public static func setVolume(_ value: UInt16, maximum: UInt16) throws -> [UInt8] {
        guard maximum > 0, value <= maximum else { throw OutputControlError.invalidVolume }
        let body: [UInt8] = [0x84, 0x03, 0x62, UInt8(value >> 8), UInt8(value & 255)]
        return body + [body.reduce(UInt8(0x6E ^ 0x51), ^)]
    }

    public static func rawValue(fraction: Double, maximum: UInt16) throws -> UInt16 {
        let value = try VolumeValidation.fraction(fraction)
        guard maximum > 0 else { throw OutputControlError.invalidVolume }
        return UInt16((value * Double(maximum)).rounded())
    }

    public static func decode(_ reply: [UInt8]) throws -> Reading {
        guard reply.count >= 11, reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02,
              reply[4] == 0x62, reply[0..<11].reduce(UInt8(0x50), ^) == 0 else {
            throw OutputControlError.invalidReply
        }
        guard reply[3] == 0 else { throw OutputControlError.unsupportedVCP }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maximum > 0, current <= maximum else { throw OutputControlError.invalidReply }
        return Reading(current: current, maximum: maximum)
    }
}

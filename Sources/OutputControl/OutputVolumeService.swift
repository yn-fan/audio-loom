import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import IOKit

private struct AudioOutput {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    var token: String { "\(id):\(uid)" }
}

private enum AudioHardware {
    static func address(_ selector: AudioObjectPropertySelector, output: Bool = false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
            mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func readValue<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             initial: T, output: Bool = false) throws -> T {
        var property = address(selector, output: output)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let code = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0)
        }
        guard code == noErr else { throw OutputControlError.systemFailure(code) }
        return value
    }

    static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var reference: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let code = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &reference)
        guard code == noErr, let reference else { throw OutputControlError.systemFailure(code) }
        return reference.takeRetainedValue() as String
    }

    static func current() throws -> AudioOutput {
        let id = try readValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
        guard id != 0 else { throw OutputControlError.noDevice }
        return AudioOutput(id: id,
            uid: try string(id, kAudioDevicePropertyDeviceUID),
            name: try string(id, kAudioObjectPropertyName),
            transport: try readValue(id, kAudioDevicePropertyTransportType, initial: UInt32(0)))
    }

    static func writableVolume(_ device: AudioDeviceID) -> AudioObjectPropertySelector? {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var property = address(selector, output: true)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &property),
               AudioObjectIsPropertySettable(device, &property, &settable) == noErr, settable.boolValue {
                return selector
            }
        }
        return nil
    }

    static func writeVolume(_ device: AudioDeviceID, selector: AudioObjectPropertySelector, fraction: Double) throws {
        var property = address(selector, output: true)
        var value = Float32(try VolumeValidation.fraction(fraction))
        let code = AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        guard code == noErr else { throw OutputControlError.systemFailure(code) }
    }
}

private final class IOAVFunctions {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    let create: Create
    let read: Transfer
    let write: Transfer
    // Keep the image loaded while its function pointers are in use.
    private let library: UnsafeMutableRawPointer

    init() throws {
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let a = dlsym(library, "IOAVServiceCreateWithService"),
              let b = dlsym(library, "IOAVServiceReadI2C"),
              let c = dlsym(library, "IOAVServiceWriteI2C") else { throw OutputControlError.unavailable }
        self.library = library
        create = unsafeBitCast(a, to: Create.self)
        read = unsafeBitCast(b, to: Transfer.self)
        write = unsafeBitCast(c, to: Transfer.self)
    }
    deinit { dlclose(library) }
}

private final class DisplayVolume {
    let token: String
    private let functions: IOAVFunctions
    private let service: CFTypeRef
    private let chipAddress: UInt32

    init(output: AudioOutput, displays: [ExternalDisplay]) throws {
        #if !arch(arm64)
        throw OutputControlError.unavailable
        #else
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            throw OutputControlError.unavailable
        }
        defer { IOObjectRelease(iterator) }
        var candidates: [io_service_t] = []
        defer { candidates.forEach { IOObjectRelease($0) } }
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if location == "External" { candidates.append(entry) } else { IOObjectRelease(entry) }
        }
        let display = try VolumeValidation.matchingDisplay(outputName: output.name, displays: displays, serviceCount: candidates.count)
        let entry = candidates[0]
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS else { throw OutputControlError.unavailable }
        let functions = try IOAVFunctions()
        guard let service = functions.create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { throw OutputControlError.unavailable }
        self.functions = functions
        self.service = service
        token = "\(output.token):display-\(display.id):service-\(registryID)"
        var parent: io_registry_entry_t = 0
        var chip: UInt32 = 0x37
        if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
            let provider = IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if provider == "AppleDCPMCDP29XX" { chip = 0xB7 }
            IOObjectRelease(parent)
        }
        chipAddress = chip
        #endif
    }

    func read() throws -> DDCVolumeProtocol.Reading {
        var lastError: Error = OutputControlError.invalidReply
        for _ in 0..<3 {
            do {
                try send(DDCVolumeProtocol.query) // Get-VCP only; does not change settings.
                usleep(50_000)
                var response = [UInt8](repeating: 0, count: 12)
                let result = response.withUnsafeMutableBytes {
                    functions.read(service, chipAddress, 0x51, $0.baseAddress!, UInt32($0.count))
                }
                guard result == kIOReturnSuccess else { throw OutputControlError.systemFailure(result) }
                return try DDCVolumeProtocol.decode(response)
            } catch OutputControlError.unsupportedVCP { throw OutputControlError.unsupportedVCP }
            catch { lastError = error; usleep(30_000) }
        }
        throw lastError
    }

    func write(_ value: UInt16, maximum: UInt16) throws {
        try send(DDCVolumeProtocol.setVolume(value, maximum: maximum))
    }

    private func send(_ bytes: [UInt8]) throws {
        var bytes = bytes
        let result = bytes.withUnsafeMutableBytes {
            functions.write(service, chipAddress, 0x51, $0.baseAddress!, UInt32($0.count))
        }
        guard result == kIOReturnSuccess else { throw OutputControlError.systemFailure(result) }
    }
}

/// All calls must be serialized on the caller's dedicated hardware queue.
/// There are no audio taps, capture streams, virtual audio devices, or file writers.
public final class OutputVolumeService: @unchecked Sendable {
    private let allowsWrites: Bool
    public init(allowsWrites: Bool = true) { self.allowsWrites = allowsWrites }

    public func inspect(displays: [ExternalDisplay]) -> OutputInspection {
        var name = "外放设备"
        do {
            let output = try AudioHardware.current()
            name = output.name
            return OutputInspection(deviceName: name, volume: try snapshot(output, displays: displays))
        } catch {
            return OutputInspection(deviceName: name, volume: nil, explanation: error.localizedDescription)
        }
    }

    public func setVolume(_ fraction: Double, expectedToken: String, displays: [ExternalDisplay]) throws -> OutputVolumeSnapshot {
        guard allowsWrites else { throw OutputControlError.readOnly }
        let fraction = try VolumeValidation.fraction(fraction)
        let output = try AudioHardware.current()
        if let selector = AudioHardware.writableVolume(output.id) {
            let token = "\(output.token):system-\(selector)"
            try VolumeValidation.requireSameDevice(expected: expectedToken, actual: token)
            try VolumeValidation.requireSameDevice(expected: output.token, actual: AudioHardware.current().token)
            try AudioHardware.writeVolume(output.id, selector: selector, fraction: fraction)
            let actual = try systemSnapshot(output, selector: selector)
            guard abs(actual.fraction - fraction) <= 0.02 else { throw OutputControlError.notApplied }
            return actual
        }
        try requireDisplayOutput(output)
        let display = try DisplayVolume(output: output, displays: displays)
        try VolumeValidation.requireSameDevice(expected: expectedToken, actual: display.token)
        let before = try display.read()
        let target = try DDCVolumeProtocol.rawValue(fraction: fraction, maximum: before.maximum)
        if target == before.current {
            return OutputVolumeSnapshot(token: display.token, deviceName: output.name, method: .displayHardware, fraction: before.fraction)
        }
        // Re-check the *current default* immediately before the only Set-VCP call.
        try VolumeValidation.requireSameDevice(expected: output.token, actual: AudioHardware.current().token)
        try display.write(target, maximum: before.maximum)
        usleep(120_000)
        let actual = try display.read()
        guard abs(Int(actual.current) - Int(target)) <= 1 else { throw OutputControlError.notApplied }
        return OutputVolumeSnapshot(token: display.token, deviceName: output.name, method: .displayHardware, fraction: actual.fraction)
    }

    private func snapshot(_ output: AudioOutput, displays: [ExternalDisplay]) throws -> OutputVolumeSnapshot {
        if let selector = AudioHardware.writableVolume(output.id) { return try systemSnapshot(output, selector: selector) }
        try requireDisplayOutput(output)
        let display = try DisplayVolume(output: output, displays: displays)
        let reading = try display.read()
        return OutputVolumeSnapshot(token: display.token, deviceName: output.name, method: .displayHardware, fraction: reading.fraction)
    }

    private func systemSnapshot(_ output: AudioOutput, selector: AudioObjectPropertySelector) throws -> OutputVolumeSnapshot {
        let value: Float32 = try AudioHardware.readValue(output.id, selector, initial: Float32(0), output: true)
        return OutputVolumeSnapshot(token: "\(output.token):system-\(selector)", deviceName: output.name, method: .system,
                                    fraction: try VolumeValidation.fraction(Double(value)))
    }

    private func requireDisplayOutput(_ output: AudioOutput) throws {
        guard output.transport == kAudioDeviceTransportTypeDisplayPort || output.transport == kAudioDeviceTransportTypeHDMI else {
            throw OutputControlError.unsupported
        }
    }
}

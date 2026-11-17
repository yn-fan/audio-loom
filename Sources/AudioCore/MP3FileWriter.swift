import AVFoundation
import Darwin
import Foundation

enum MP3Error: LocalizedError {
    case unavailable, initialization, encoding(Int32), invalidTag
    var errorDescription: String? {
        switch self {
        case .unavailable: return "随附的 MP3 编码器未能加载，请重新安装完整的声流应用。"
        case .initialization: return "无法初始化 MP3 编码器。"
        case .encoding(let code): return "MP3 编码失败（\(code)）。已有文件将保留。"
        case .invalidTag: return "MP3 文件的时长信息未能正确写入。"
        }
    }
}

private final class LameLibrary {
    typealias InitFunction = @convention(c) () -> OpaquePointer?
    typealias Setter = @convention(c) (OpaquePointer, Int32) -> Int32
    typealias VoidSetter = @convention(c) (OpaquePointer, Int32) -> Void
    typealias HandleFunction = @convention(c) (OpaquePointer) -> Int32
    typealias Encode = @convention(c) (OpaquePointer, UnsafePointer<Float>, UnsafePointer<Float>,
        Int32, UnsafeMutablePointer<UInt8>, Int32) -> Int32
    typealias EncodeInterleaved = @convention(c) (OpaquePointer, UnsafePointer<Float>,
        Int32, UnsafeMutablePointer<UInt8>, Int32) -> Int32
    typealias Flush = @convention(c) (OpaquePointer, UnsafeMutablePointer<UInt8>, Int32) -> Int32
    typealias Tag = @convention(c) (OpaquePointer, UnsafeMutablePointer<UInt8>?, UInt) -> UInt

    static let shared: Result<LameLibrary, Error> = Result { try LameLibrary() }
    let initialize: InitFunction
    let setInputRate: Setter
    let setOutputRate: Setter
    let setChannels: Setter
    let setBitrate: Setter
    let setQuality: Setter
    let setVBR: Setter
    let setWriteTag: Setter
    let setAutomaticID3: VoidSetter
    let initializeParameters: HandleFunction
    let encode: Encode
    let encodeInterleaved: EncodeInterleaved
    let flush: Flush
    let tag: Tag
    let close: HandleFunction
    private let library: UnsafeMutableRawPointer

    private init() throws {
        let url: URL
        if Bundle.main.bundleIdentifier == "local.learning.audioloom" {
            guard let frameworks = Bundle.main.privateFrameworksURL else { throw MP3Error.unavailable }
            url = frameworks.appendingPathComponent("libmp3lame.0.dylib")
        } else {
            // Swift Package tests/development. Installed apps only load their own bundled library.
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Vendor/LAME/libmp3lame.0.dylib")
        }
        guard let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw MP3Error.unavailable }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw MP3Error.unavailable }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            initialize = try symbol("lame_init", as: InitFunction.self)
            setInputRate = try symbol("lame_set_in_samplerate", as: Setter.self)
            setOutputRate = try symbol("lame_set_out_samplerate", as: Setter.self)
            setChannels = try symbol("lame_set_num_channels", as: Setter.self)
            setBitrate = try symbol("lame_set_brate", as: Setter.self)
            setQuality = try symbol("lame_set_quality", as: Setter.self)
            setVBR = try symbol("lame_set_VBR", as: Setter.self)
            setWriteTag = try symbol("lame_set_bWriteVbrTag", as: Setter.self)
            setAutomaticID3 = try symbol("lame_set_write_id3tag_automatic", as: VoidSetter.self)
            initializeParameters = try symbol("lame_init_params", as: HandleFunction.self)
            encode = try symbol("lame_encode_buffer_ieee_float", as: Encode.self)
            encodeInterleaved = try symbol("lame_encode_buffer_interleaved_ieee_float", as: EncodeInterleaved.self)
            flush = try symbol("lame_encode_flush", as: Flush.self)
            tag = try symbol("lame_get_lametag_frame", as: Tag.self)
            close = try symbol("lame_close", as: HandleFunction.self)
            self.library = library
        } catch {
            dlclose(library)
            throw error
        }
    }
    deinit { dlclose(library) }
}

/// Streaming encoder: normalized float PCM is encoded directly, without a
/// temporary WAV, a subprocess, a virtual driver, or any network service.
final class MP3FileWriter {
    private let library: LameLibrary
    private let channels: Int
    private var encoder: OpaquePointer?
    private var file: FileHandle?
    private var finished = false

    init(url: URL, format: AVAudioFormat) throws {
        library = try LameLibrary.shared.get()
        channels = Int(format.channelCount)
        guard channels == 1 || channels == 2, format.commonFormat == .pcmFormatFloat32,
              [32_000.0, 44_100, 48_000].contains(format.sampleRate),
              let handle = library.initialize() else { throw MP3Error.initialization }
        encoder = handle
        for result in [
            library.setInputRate(handle, Int32(format.sampleRate)),
            library.setOutputRate(handle, Int32(format.sampleRate)),
            library.setChannels(handle, Int32(channels)),
            library.setBitrate(handle, 320),
            library.setQuality(handle, 2),
            library.setVBR(handle, 0), // vbr_off: constant 320 kbps.
            library.setWriteTag(handle, 1)
        ] {
            guard result == 0 else { throw MP3Error.initialization }
        }
        // Put the Info/LAME frame at byte zero, so final duration/delay metadata
        // can replace the reserved frame unambiguously when recording stops.
        library.setAutomaticID3(handle, 0)
        guard library.initializeParameters(handle) == 0 else { throw MP3Error.initialization }
        file = try FileHandle(forWritingTo: url) // Caller reserved the path exclusively.
    }

    func write(_ pcm: AVAudioPCMBuffer) throws {
        guard !finished, let encoder, let file,
              pcm.format.commonFormat == .pcmFormatFloat32,
              Int(pcm.format.channelCount) == channels,
              let data = pcm.floatChannelData else { throw AudioError.invalidBuffer }
        var offset = 0
        while offset < Int(pcm.frameLength) {
            let count = min(16_384, Int(pcm.frameLength) - offset)
            let capacity = 7200 + (count * 5 + 3) / 4
            var output = [UInt8](repeating: 0, count: capacity)
            let length = output.withUnsafeMutableBufferPointer { bytes -> Int32 in
                if pcm.format.isInterleaved && channels == 2 {
                    return library.encodeInterleaved(encoder, data[0].advanced(by: offset * channels),
                        Int32(count), bytes.baseAddress!, Int32(capacity))
                }
                let left = data[0].advanced(by: offset)
                let right = channels == 1 ? left : data[1].advanced(by: offset)
                return library.encode(encoder, left, right, Int32(count), bytes.baseAddress!, Int32(capacity))
            }
            guard length >= 0 else { throw MP3Error.encoding(length) }
            if length > 0 { try file.write(contentsOf: Data(output.prefix(Int(length)))) }
            offset += count
        }
    }

    func finish() throws {
        guard !finished else { return }
        finished = true
        defer { releaseResources() }
        guard let encoder, let file else { throw MP3Error.initialization }
        var finalBytes = [UInt8](repeating: 0, count: 7200)
        let count = finalBytes.withUnsafeMutableBufferPointer {
            library.flush(encoder, $0.baseAddress!, Int32($0.count))
        }
        guard count >= 0 else { throw MP3Error.encoding(count) }
        if count > 0 { try file.write(contentsOf: Data(finalBytes.prefix(Int(count)))) }
        let fileLength = try file.offset()
        let required = library.tag(encoder, nil, 0)
        guard required > 0, required <= 16_384, UInt64(required) <= fileLength else { throw MP3Error.invalidTag }
        var tag = [UInt8](repeating: 0, count: Int(required))
        let tagLength = tag.withUnsafeMutableBufferPointer { library.tag(encoder, $0.baseAddress, UInt($0.count)) }
        guard tagLength == required else { throw MP3Error.invalidTag }
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Data(tag))
        try file.synchronize()
        try file.close()
        self.file = nil
    }

    private func releaseResources() {
        if let encoder { _ = library.close(encoder); self.encoder = nil }
        try? file?.close()
        file = nil
    }
    deinit { releaseResources() }
}

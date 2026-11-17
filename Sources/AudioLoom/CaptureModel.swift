import AppKit
import AudioCore
import AVFoundation
import Combine
import ScreenCaptureKit

struct AudioSource: Identifiable {
    let id: Int32
    let name: String
}

// Mutable audio state is confined to queue; immutable callbacks run on the main actor.
private final class StreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.audioloom.audio-writer", qos: .userInitiated)
    private let recorder: AudioFileRecorder
    private var plan: RoutingPlan
    private var active = true
    private var lastMeterTime = 0.0
    private var heldPeaks: [Float] = [0, 0]
    private var heldClip = false
    private var waveform = WaveformEnvelope()
    private let onMeter: @MainActor @Sendable (MeterReading, TimeInterval, [WaveformBin]) -> Void
    private let onFailure: @MainActor @Sendable (Error) -> Void

    init(recorder: AudioFileRecorder, plan: RoutingPlan,
         onMeter: @escaping @MainActor @Sendable (MeterReading, TimeInterval, [WaveformBin]) -> Void,
         onFailure: @escaping @MainActor @Sendable (Error) -> Void) throws {
        self.recorder = recorder
        self.plan = plan
        self.onMeter = onMeter
        self.onFailure = onFailure
    }

    func update(plan: RoutingPlan) {
        queue.async { self.plan = plan }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        // Screen frames are discarded immediately. No images are saved or inspected.
        guard type == .audio, active, sample.isValid,
              CMSampleBufferGetNumSamples(sample) > 0 else { return }
        do {
            let buffer = try AudioProcessor.copyPCM(from: sample)
            let meter = try plan.process(buffer)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try recorder.append(buffer, timestamp: timestamp.isFinite ? timestamp : nil)
            try waveform.append(buffer, timestamp: timestamp.isFinite ? timestamp : nil)
            for index in 0..<min(heldPeaks.count, meter.peaks.count) {
                heldPeaks[index] = max(heldPeaks[index], meter.peaks[index])
            }
            heldClip = heldClip || meter.clipped
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastMeterTime >= 0.08 {
                lastMeterTime = now
                let peak = MeterReading(peaks: heldPeaks, clipped: heldClip)
                let duration = recorder.duration
                let envelope = waveform.snapshot
                heldPeaks = [0, 0]
                heldClip = false
                DispatchQueue.main.async { self.onMeter(peak, duration, envelope) }
            }
        } catch {
            active = false
            DispatchQueue.main.async { self.onFailure(error) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onFailure(error) }
    }

    func finish() async -> (URL?, TimeInterval, Error?) {
        await withCheckedContinuation { continuation in
            queue.async {
                self.active = false
                let duration = self.recorder.duration
                let url = self.recorder.finish()
                continuation.resume(returning: (url, duration, self.recorder.finishError))
            }
        }
    }
}

@MainActor
final class CaptureModel: ObservableObject {
    enum Phase { case idle, starting, recording, stopping }
    @Published private(set) var sources: [AudioSource] = []
    @Published var selectedSource: Int32 = 0
    @Published private(set) var graph: AudioGraph
    @Published private(set) var outputFormat: RecordingFormat
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peaks: [Float] = [0, 0]
    @Published private(set) var waveform = Array(repeating: WaveformBin.silence, count: 96)
    @Published private(set) var hasAudioVisualization = false
    @Published private(set) var visualizationIsSynthetic = false
    @Published private(set) var clipped = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lastRecording: URL?
    @Published private(set) var message = "点击开始后自动保存到下载文件夹。"
    @Published private(set) var hasError = false
    private var stream: SCStream?
    private var sink: StreamSink?
    private var recordingID = UUID()
    private var meterUpdatedAt = Date.distantPast
    private var clipUntil = Date.distantPast
    private var decayTimer: Timer?
    private let persistsSettings: Bool
    private let revealFile: @MainActor (URL) -> Void
    private static let graphKey = "AudioLoom.routingGraph.v2"
    private static let formatKey = "AudioLoom.outputFormat.v3"

    var isActive: Bool { phase != .idle }
    var isBusy: Bool { phase == .starting || phase == .stopping }
    var route: RoutingPlan? { try? graph.compile() }
    var routeError: String? {
        do { _ = try graph.compile(); return nil }
        catch { return error.localizedDescription }
    }
    var quickGainNode: AudioNode? { route?.nodes.first { $0.kind == .gain && !$0.bypassed } }
    var muted: Bool { graph.nodes.first { $0.kind == .recorder }?.muted ?? false }
    var recordingIsSilenced: Bool {
        muted || (route?.nodes.contains { $0.kind == .gain && !$0.bypassed && $0.gain == 0 } ?? false)
    }
    var sourceName: String { selectedSource == 0 ? "系统声音" : (sources.first { $0.id == selectedSource }?.name ?? "应用已退出") }
    var compactDurationText: String { RecordingIndicator.clock(duration) }
    var durationText: String {
        let seconds = Int(duration)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    init(preview: Bool = false,
         revealFile: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        persistsSettings = !preview
        self.revealFile = revealFile
        outputFormat = preview ? .wav : RecordingFormat(rawValue: UserDefaults.standard.string(forKey: Self.formatKey) ?? "") ?? .wav
        if !preview, let data = UserDefaults.standard.data(forKey: Self.graphKey),
           let saved = try? JSONDecoder().decode(AudioGraph.self, from: data),
           (try? saved.validateStructure()) != nil {
            graph = saved
        } else {
            graph = .standard()
        }
        refreshSources()
        decayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Date().timeIntervalSince(self.meterUpdatedAt) > 0.25,
                   !self.visualizationIsSynthetic, self.peaks.contains(where: { $0 != 0 }) {
                    self.peaks = [0, 0]
                }
                let clipped = Date() < self.clipUntil
                if clipped != self.clipped { self.clipped = clipped }
            }
        }
    }

    func refreshSources() {
        guard !isActive else { return }
        sources = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .map { AudioSource(id: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "未命名应用") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if selectedSource != 0 && !sources.contains(where: { $0.id == selectedSource }) { selectedSource = 0 }
    }

    func startRecording() async {
        guard phase == .idle else { return }
        // A snapshot/test launch must never start capture or write into Downloads,
        // even if an automated click accidentally reaches the record button.
        guard persistsSettings else {
            message = "预览模式不会开始录音或写入下载文件夹。"
            return
        }
        guard route != nil else {
            hasError = true
            message = routeError ?? "请先连接音频流程。"
            return
        }
        // No save panel: clicking Record is the explicit request to capture.
        // Lock the route and format throughout connection and file reservation.
        let recordingFormat = outputFormat
        phase = .starting
        hasError = false
        duration = 0
        peaks = [0, 0]
        waveform = Array(repeating: .silence, count: 96)
        hasAudioVisualization = false
        visualizationIsSynthetic = false
        clipped = false
        clipUntil = .distantPast
        message = "正在连接音源。如有权限提示，请允许后再继续。"
        let id = UUID()
        recordingID = id
        do {
            let directory = try RecordingDestination.downloadsDirectory()
            try RecordingDestination.prepareDirectory(directory)
            // Only this user-initiated path queries ScreenCaptureKit.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard phase == .starting, recordingID == id else { return }
            guard let display = content.displays.first else {
                throw NSError(domain: "AudioLoom", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有找到可用显示器。请连接显示器后重试。"])
            }
            let filter: SCContentFilter
            if selectedSource == 0 {
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            } else {
                guard let app = content.applications.first(where: { $0.processID == selectedSource }) else {
                    throw NSError(domain: "AudioLoom", code: 2, userInfo: [NSLocalizedDescriptionKey: "该应用当前不可捕获。请打开它的窗口并播放声音，再刷新音源重试。"])
                }
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // ScreenCaptureKit uses a display filter; minimize the unused video path.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            config.showsCursor = false
            let recorder = try RecordingDestination.createRecorder(in: directory, format: recordingFormat)
            let output = try StreamSink(recorder: recorder, plan: graph.compile()) { [weak self] meter, elapsed, envelope in
                guard let self, self.recordingID == id, self.phase == .recording || self.phase == .starting else { return }
                self.peaks = meter.peaks
                self.duration = elapsed
                self.waveform = envelope
                self.hasAudioVisualization = true
                self.meterUpdatedAt = Date()
                if meter.clipped { self.clipUntil = Date().addingTimeInterval(1) }
                self.clipped = Date() < self.clipUntil
                if self.phase == .recording {
                    self.message = self.muted ? "静音写入中。" : "正在录音，关闭弹窗不会中断。"
                }
            } onFailure: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.recordingID == id, self.isActive else { return }
                    await self.stop(error: error)
                }
            }
            sink = output
            let capture = SCStream(filter: filter, configuration: config, delegate: output)
            stream = capture
            try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await capture.startCapture()
            guard phase == .starting, recordingID == id else { return }
            phase = .recording
            message = "等待声音，请让所选音源开始播放。"
        } catch {
            if phase == .starting, recordingID == id { await stop(error: error) }
        }
    }

    func stop(error initialError: Error? = nil, revealWhenSaved: Bool = false) async {
        guard phase != .idle, phase != .stopping else { return }
        phase = .stopping
        message = "正在结束录音并保存文件…"
        var failure = initialError
        if let stream {
            do { try await stream.stopCapture() }
            catch { if failure == nil { failure = error } }
        }
        let result = await sink?.finish()
        if failure == nil { failure = result?.2 }
        stream = nil
        sink = nil
        applySaveResult(savedURL: result?.0, elapsed: result?.1, failure: failure, reveal: revealWhenSaved)
    }

    private func applySaveResult(savedURL: URL?, elapsed: TimeInterval?, failure: Error?, reveal: Bool) {
        peaks = [0, 0]
        phase = .idle
        hasError = failure != nil || savedURL == nil
        if let elapsed { duration = elapsed }
        if let saved = savedURL {
            lastRecording = saved
            message = failure.map { "已保留已写入的文件。\($0.localizedDescription)" } ?? "已保存到下载文件夹。"
        } else {
            message = failure.map {
                "未能录音：\($0.localizedDescription)\n录制权限可在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」检查；下载目录访问权限可在「文件与文件夹」中检查。"
            } ?? "没有收到音频数据，未保留空文件。请确认音源正在播放。"
        }
        if let url = RecordingCompletionPresentation.revealURL(savedURL: savedURL, failed: failure != nil, requested: reveal) {
            revealFile(url)
        }
    }

    private func commit(_ updated: AudioGraph) {
        graph = updated
        if let plan = try? graph.compile() { sink?.update(plan: plan) }
        if persistsSettings, let data = try? JSONEncoder().encode(graph) {
            UserDefaults.standard.set(data, forKey: Self.graphKey)
        }
    }

    func setOutputFormat(_ value: RecordingFormat) {
        guard !isActive else { return }
        outputFormat = value
        if persistsSettings { UserDefaults.standard.set(value.rawValue, forKey: Self.formatKey) }
    }

    func setGain(_ id: UUID, value: Double) {
        guard value.isFinite, let index = graph.nodes.firstIndex(where: { $0.id == id && $0.kind == .gain }) else { return }
        var changed = graph
        changed.nodes[index].gain = Float(min(2, max(0, value)))
        commit(changed)
    }

    func setMuted(_ value: Bool) {
        guard let index = graph.nodes.firstIndex(where: { $0.kind == .recorder }) else { return }
        var changed = graph
        changed.nodes[index].muted = value
        commit(changed)
    }

    func setBypassed(_ id: UUID, value: Bool) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id && $0.kind.isProcessor }) else { return }
        var changed = graph
        changed.nodes[index].bypassed = value
        commit(changed)
    }

    func moveNode(_ id: UUID, x: Double, y: Double) {
        guard !isActive, let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        var changed = graph
        changed.nodes[index].x = min(1_900, max(76, x))
        changed.nodes[index].y = min(1_900, max(48, y))
        commit(changed)
    }

    func connect(from: UUID, to: UUID) throws {
        guard !isActive else { return }
        var changed = graph
        try changed.connect(from: from, to: to)
        commit(changed)
    }

    func disconnect(_ connection: AudioConnection) {
        guard !isActive else { return }
        var changed = graph
        changed.disconnect(connection)
        commit(changed)
    }

    func addNode(_ kind: NodeKind) throws -> UUID? {
        guard !isActive else { return nil }
        var changed = graph
        let id = try changed.addProcessor(kind)
        commit(changed)
        return id
    }

    func removeNode(_ id: UUID) {
        guard !isActive else { return }
        var changed = graph
        changed.removeProcessor(id)
        commit(changed)
    }

    func resetGraph() {
        guard !isActive else { return }
        commit(.standard())
    }

    func revealRecording() {
        if let lastRecording { revealFile(lastRecording) }
    }

    func openRecordingFolder() {
        if let directory = try? RecordingDestination.downloadsDirectory() { NSWorkspace.shared.open(directory) }
    }

    /// Tests use an injected Finder callback. This is not a capture/file-writing
    /// path and cannot alter the live app's recording state.
    func previewSaveResult(url: URL?, failed: Bool, reveal: Bool) {
        guard !persistsSettings else { return }
        applySaveResult(savedURL: url, elapsed: 3, failure: failed ? AudioError.invalidBuffer : nil, reveal: reveal)
    }

    /// Only available to the non-persisting snapshot/test model. No input device,
    /// capture stream or audio playback is used for this visual inspection.
    func setSyntheticVisualization(_ buffer: AVAudioPCMBuffer?) throws {
        guard !persistsSettings, phase == .idle else { return }
        if let buffer {
            var envelope = WaveformEnvelope()
            try envelope.append(buffer)
            waveform = envelope.snapshot
            let meter = try AudioProcessor.process(buffer, gain: 1, muted: false)
            peaks = meter.peaks
            visualizationIsSynthetic = true
            hasAudioVisualization = true
        } else {
            waveform = Array(repeating: .silence, count: 96)
            peaks = [0, 0]
            visualizationIsSynthetic = false
            hasAudioVisualization = false
        }
    }
}

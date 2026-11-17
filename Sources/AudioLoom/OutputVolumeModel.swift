import AppKit
import Combine
import OutputControl

/// This object has no CaptureModel reference. It can operate before, during, or
/// after recording, and only talks to hardware/device volume interfaces.
@MainActor
final class OutputVolumeModel: ObservableObject {
    @Published private(set) var deviceName = "当前扬声器"
    @Published private(set) var snapshot: OutputVolumeSnapshot?
    @Published private(set) var fraction: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var error: String?
    private let preview: Bool
    private let hardware = OutputVolumeService()
    private let queue = DispatchQueue(label: "local.audioloom.output-hardware", qos: .userInitiated)
    private var timer: Timer?
    private var visible = false
    private var readInFlight = false
    private var pending: DispatchWorkItem?
    private var revision: UInt64 = 0
    private var rememberedLevels: [String: Double] = [:]

    var canAdjust: Bool { snapshot != nil }
    var isPreviewMode: Bool { preview }
    var percentage: String { canAdjust ? "\(Int((fraction * 100).rounded()))%" : isLoading ? "读取中" : "不可调" }

    init(preview: Bool) {
        self.preview = preview
        if preview {
            publish(OutputVolumeSnapshot(token: "preview-only", deviceName: "外接显示器", method: .displayHardware, fraction: 0.5))
        }
    }

    func setVisible(_ value: Bool) {
        visible = value
        timer?.invalidate()
        timer = nil
        guard value, !preview else { return }
        refresh()
        // Avoid polling or waking a display while the popover is closed.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        guard !preview, !readInFlight, !isApplying, pending == nil else { return }
        readInFlight = true
        if snapshot == nil { isLoading = true }
        let displays = externalDisplays()
        let id = revision
        queue.async { [hardware, weak self] in
            let inspection = hardware.inspect(displays: displays)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readInFlight = false
                guard self.revision == id else { return }
                self.isLoading = false
                self.deviceName = inspection.deviceName
                if let volume = inspection.volume {
                    self.publish(volume)
                } else {
                    self.snapshot = nil
                    self.error = inspection.explanation
                }
            }
        }
    }

    func requestVolume(_ value: Double) {
        guard let current = snapshot, let value = try? VolumeValidation.fraction(value) else { return }
        revision &+= 1
        let id = revision
        pending?.cancel()
        fraction = value
        error = nil
        if preview {
            publish(OutputVolumeSnapshot(token: current.token, deviceName: current.deviceName, method: current.method, fraction: value))
            return
        }
        // Coalesce rapid slider events; don't hammer DDC with every mouse frame.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revision == id else { return }
            self.pending = nil
            self.isApplying = true
            let displays = self.externalDisplays()
            self.queue.async { [hardware = self.hardware, weak self] in
                let result = Result { try hardware.setVolume(value, expectedToken: current.token, displays: displays) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == id else { return }
                    self.isApplying = false
                    switch result {
                    case .success(let confirmed): self.publish(confirmed)
                    case .failure(let failure):
                        self.fraction = self.snapshot?.fraction ?? 0
                        self.error = failure.localizedDescription
                        // The next read will refresh the actual device/value, never
                        // re-apply the user's old value to a newly selected device.
                    }
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func toggleSilence() {
        guard let current = snapshot, !isApplying else { return }
        if fraction > 0.001 {
            rememberedLevels[current.token] = fraction
            requestVolume(0)
        } else {
            requestVolume(rememberedLevels[current.token] ?? 0.25)
        }
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
        timer?.invalidate()
    }

    private func publish(_ value: OutputVolumeSnapshot) {
        snapshot = value
        deviceName = value.deviceName
        fraction = value.fraction
        error = nil
        if value.fraction > 0.001 { rememberedLevels[value.token] = value.fraction }
    }

    private func externalDisplays() -> [ExternalDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsBuiltin(number.uint32Value) == 0 else { return nil }
            return ExternalDisplay(id: number.uint32Value, name: screen.localizedName)
        }
    }
}

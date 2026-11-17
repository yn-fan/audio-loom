import AppKit
import AudioCore
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = CaptureModel(preview: CommandLine.arguments.contains("--snapshot-directory"))
    let outputVolume = OutputVolumeModel(preview: CommandLine.arguments.contains("--snapshot-directory"))
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var routingWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var lastIndicator: RecordingIndicator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--snapshot-directory") {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        // Keep the inspection popover open when the QA driver activates the app.
        // Normal user launches retain the expected click-outside-to-dismiss behavior.
        popover.behavior = CommandLine.arguments.contains("--snapshot-directory") ? .applicationDefined : .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView(
            model: model,
            outputVolume: outputVolume,
            onRecord: { [weak self] in self?.record() },
            onEdit: { [weak self] in self?.showRoutingEditor() },
            onDetails: { [weak self] in self?.showDetails() },
            onQuit: { NSApp.terminate(nil) }
        ))
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncPopoverAppearance() }
        }
        // Published properties announce before assignment; defer delivery so the
        // indicator reads a coherent phase, duration, mute flag and error message.
        model.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &subscriptions)
        updateStatusItem()
        runSnapshotIfRequested()
        if CommandLine.arguments.contains("--show-menu"),
           !CommandLine.arguments.contains("--snapshot-directory") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                if self?.popover.isShown == false { self?.togglePopover() }
            }
        }
    }

    private func updateStatusItem() {
        let phase: RecordingIndicatorPhase
        switch model.phase {
        case .idle: phase = model.hasError ? .attention : .idle
        case .starting: phase = .connecting
        case .recording: phase = .recording
        case .stopping: phase = .saving
        }
        applyIndicator(.make(phase: phase, duration: model.duration, muted: model.recordingIsSilenced,
                             source: model.sourceName, format: model.outputFormat.title, error: model.message))
    }

    private func applyIndicator(_ indicator: RecordingIndicator) {
        guard indicator != lastIndicator, let item = statusItem, let button = item.button else { return }
        lastIndicator = indicator
        let image: NSImage?
        if indicator.tone == .recording {
            image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            image?.isTemplate = false
        } else {
            let symbol = NSImage(systemSymbolName: indicator.symbol, accessibilityDescription: indicator.tooltip)
            if indicator.tone == .warning {
                image = symbol?.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
                image?.isTemplate = false
            } else {
                image = symbol
                image?.isTemplate = true
            }
            image?.size = NSSize(width: 16, height: 16)
        }
        item.length = indicator.usesVariableWidth ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        button.imagePosition = indicator.title.isEmpty ? .imageOnly : .imageLeading
        button.image = image
        button.title = indicator.title
        button.toolTip = indicator.tooltip
        button.setAccessibilityLabel(indicator.tooltip.replacingOccurrences(of: "\n", with: "，"))
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        model.refreshSources()
        guard let button = statusItem?.button else { return }
        syncPopoverAppearance()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillShow(_ notification: Notification) { outputVolume.setVisible(true) }
    func popoverDidClose(_ notification: Notification) { outputVolume.setVisible(false) }

    private func syncPopoverAppearance() {
        // The menu-bar button's vibrancy can differ from the system app appearance.
        // Use the app's standard appearance for readable native controls in the popover.
        let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        let appearance = NSAppearance(named: name)
        popover.appearance = appearance
        popover.contentViewController?.view.appearance = appearance
    }

    private func record() {
        if model.phase == .recording {
            Task { await model.stop(revealWhenSaved: true) }
        } else {
            // Keep the panel visible for the waveform and faders; no save dialog.
            Task { await model.startRecording() }
        }
    }

    private func showDetails() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "录音未完成"
        alert.informativeText = model.message
        alert.runModal()
    }

    private func showRoutingEditor() {
        popover.performClose(nil)
        model.refreshSources()
        if routingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "高级处理"
            window.contentViewController = NSHostingController(rootView: RoutingEditor(model: model))
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 390)
            window.center()
            routingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        routingWindow?.makeKeyAndOrderFront(nil)
    }

    // Closing either UI never stops the menu-bar utility or an active recording.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        outputVolume.cancelPending()
        guard model.isActive else { return .terminateNow }
        Task {
            await model.stop()
            while model.isActive { try? await Task.sleep(nanoseconds: 50_000_000) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Captures only our own rendered views; never starts audio/screen capture.
    private func runSnapshotIfRequested() {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshot-directory"),
              CommandLine.arguments.indices.contains(index + 1) else { return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            togglePopover()
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let view = popover.contentViewController?.view {
                saveSnapshot(view, to: folder.appendingPathComponent("menu.png"))
                if CommandLine.arguments.contains("--exercise-ui") {
                    await UISmokeTests.runPopover(view: view, model: model, folder: folder)
                    await DeckUITests.run(view: view, model: model, folder: folder)
                    await FaderUITests.run(view: view, model: model, output: outputVolume, folder: folder)
                    model.setOutputFormat(.m4a)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    saveSnapshot(view, to: folder.appendingPathComponent("menu-m4a.png"))
                    model.setOutputFormat(.wav)
                    FaderUITests.showSyntheticSignal(model: model, folder: folder)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    saveSnapshot(view, to: folder.appendingPathComponent("menu-signal.png"))
                    try? model.setSyntheticVisualization(nil)
                }
            }
            showRoutingEditor()
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let view = routingWindow?.contentView {
                saveSnapshot(view, to: folder.appendingPathComponent("routing.png"))
            }
            if CommandLine.arguments.contains("--exercise-ui"), let routingWindow {
                await UISmokeTests.run(window: routingWindow, model: model, folder: folder)
                UISmokeTests.runOutputIndependence(model: model, output: outputVolume, folder: folder)
                UISmokeTests.runBundledMP3(folder: folder)
                await UISmokeTests.runPreviewCaptureGuard(model: model, folder: folder)
                UISmokeTests.runSavePresentation(folder: folder)
                checkIndicatorPresentation(folder: folder)
            }
            NSApp.terminate(nil)
        }
    }

    private func saveSnapshot(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }

    /// Property checks occur synchronously and restore the actual state before
    /// the next display frame: no simulated recording indicator is left running.
    private func checkIndicatorPresentation(folder: URL) {
        guard CommandLine.arguments.contains("--snapshot-directory"), let item = statusItem, let button = item.button else { return }
        var checks: [String: Bool] = [:]
        applyIndicator(.make(phase: .recording, duration: 73, source: "测试音源", format: "MP3"))
        checks["recording_time_visible"] = button.title == "01:13" && item.length == NSStatusItem.variableLength
        checks["recording_has_colored_dot"] = button.image != nil && button.image?.isTemplate == false
        applyIndicator(.make(phase: .recording, duration: 73, muted: true))
        checks["recording_mute_visible"] = button.title.contains("静音")
        applyIndicator(.make(phase: .saving))
        checks["saving_status_visible"] = button.title == "保存"
        applyIndicator(.make(phase: .attention, error: "测试错误"))
        checks["error_status_has_explanation"] = button.toolTip?.contains("测试错误") == true && button.image != nil
        applyIndicator(.make(phase: .idle))
        checks["idle_returns_to_compact_icon"] = button.title.isEmpty && item.length == NSStatusItem.squareLength
        lastIndicator = nil
        updateStatusItem()
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("menu-bar-ui-tests.json"))
        }
    }
}

@main
enum AudioLoomApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

import AppKit
import AudioCore
import AVFoundation
import Foundation

/// Opt-in QA only, on a non-persisting preview model.
/// Events are posted exclusively to this application's own editor window.
/// No accessibility permission, screen capture, audio capture, or external app control.
@MainActor
enum UISmokeTests {
    static func runPreviewCaptureGuard(model: CaptureModel, folder: URL) async {
        await model.startRecording()
        let checks = [
            "preview_cannot_start_capture": model.phase == .idle && model.duration == 0 && model.lastRecording == nil,
            "preview_explicitly_reports_no_download_writes": model.message.contains("不会开始录音或写入下载文件夹"),
            "no_save_panel_presented": !NSApp.windows.contains { $0 is NSSavePanel }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("automatic-save-ui-tests.json"))
        }
    }

    static func runBundledMP3(folder: URL) {
        var report: [String: Any] = ["passed": false, "syntheticOnly": true]
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            pcm.frameLength = 48_000
            for index in 0..<48_000 {
                let sample = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.1
                pcm.floatChannelData![0][index] = sample
                pcm.floatChannelData![1][index] = sample
            }
            let url = folder.appendingPathComponent("encoder-check-\(UUID()).mp3")
            let writer = try AudioFileRecorder(url: url, outputFormat: .mp3)
            try writer.append(pcm)
            writer.finish()
            if let error = writer.finishError { throw error }
            let reader = try AVAudioFile(forReading: url)
            report["passed"] = reader.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEGLayer3
                && abs(reader.length - 48_000) <= 2304
            report["file"] = url.path
            report["library"] = Bundle.main.privateFrameworksURL?.appendingPathComponent("libmp3lame.0.dylib").path ?? ""
            report["frames"] = reader.length
        } catch { report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("bundled-mp3-test.json"))
        }
    }

    static func runPopover(view: NSView, model: CaptureModel, folder: URL) async {
        guard let window = view.window else { return }
        var results = [String: Bool]()
        var selected: [String] = []
        NativeMenuTestTrace.events = []
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        try? await Task.sleep(nanoseconds: 200_000_000)
        results["popover_visible_for_test"] = window.isVisible
        func findAnchor(in view: NSView) -> NSView? {
            if view.identifier?.rawValue == "format-menu-anchor" { return view }
            for child in view.subviews { if let match = findAnchor(in: child) { return match } }
            return nil
        }
        guard let anchor = findAnchor(in: view) else {
            let data = try? JSONSerialization.data(withJSONObject: ["format_anchor_found": false])
            try? data?.write(to: folder.appendingPathComponent("format-ui-tests.json"))
            return
        }
        let location = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
        func selectFormat(index: Int) async {
            NativeMenuTestTrace.requestedTitle = RecordingFormat.allCases[index].menuTitle
            let now = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        // Establish normal menu focus before checking individual item actions.
        await selectFormat(index: 0)
        await selectFormat(index: 1)
        selected.append(model.outputFormat.rawValue)
        results["format_menu_action_selects_m4a"] = model.outputFormat == .m4a
        await selectFormat(index: 2)
        selected.append(model.outputFormat.rawValue)
        results["format_menu_action_selects_aiff"] = model.outputFormat == .aiff
        await selectFormat(index: 3)
        selected.append(model.outputFormat.rawValue)
        results["format_menu_action_selects_mp3"] = model.outputFormat == .mp3
        await selectFormat(index: 0)
        selected.append(model.outputFormat.rawValue)
        results["format_menu_action_selects_wav"] = model.outputFormat == .wav
        results["format_selection_never_records"] = model.phase == .idle && model.duration == 0
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("format-ui-tests.json"))
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["selected": selected, "events": NativeMenuTestTrace.events], options: [.prettyPrinted]) {
            try? data.write(to: folder.appendingPathComponent("format-ui-trace.json"))
        }
    }

    static func runSavePresentation(folder: URL) {
        var requests: [URL] = []
        var readyAtReveal: [Bool] = []
        weak var observed: CaptureModel?
        let probe = CaptureModel(preview: true, revealFile: { url in
            requests.append(url)
            readyAtReveal.append(observed?.phase == .idle && observed?.lastRecording == url && observed?.hasError == false)
        })
        observed = probe
        let completed = folder.appendingPathComponent("completed-example.mp3")
        let partial = folder.appendingPathComponent("partial-example.mp3")
        var checks: [String: Bool] = [:]
        probe.previewSaveResult(url: completed, failed: false, reveal: true)
        checks["successful_user_stop_requests_exact_file"] = requests == [completed]
        checks["completed_state_precedes_reveal"] = readyAtReveal == [true]
        probe.previewSaveResult(url: partial, failed: true, reveal: true)
        checks["failed_save_does_not_open_finder"] = requests == [completed] && probe.hasError
        probe.previewSaveResult(url: nil, failed: false, reveal: true)
        checks["empty_save_does_not_reveal_old_file"] = requests == [completed] && probe.hasError
        probe.previewSaveResult(url: completed, failed: false, reveal: false)
        checks["quitting_does_not_interrupt_with_finder"] = requests == [completed]
        checks["no_capture_started"] = probe.phase == .idle
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("save-presentation-tests.json"))
        }
    }

    static func runOutputIndependence(model: CaptureModel, output: OutputVolumeModel, folder: URL) {
        precondition(output.isPreviewMode, "UI checks must never adjust real hardware")
        var results = [String: Bool]()
        let graph = model.graph
        let format = model.outputFormat
        let original = output.fraction
        output.requestVolume(0.23)
        results["output_can_change_while_not_recording"] = output.fraction == 0.23 && model.phase == .idle
        results["output_does_not_change_recording_graph"] = model.graph == graph && model.outputFormat == format
        if let gain = model.quickGainNode {
            model.setGain(gain.id, value: 0.4)
            results["recording_gain_does_not_change_output"] = output.fraction == 0.23
            model.setGain(gain.id, value: Double(gain.gain))
        }
        output.toggleSilence()
        results["output_silence_independent"] = output.fraction == 0 && !model.muted
        output.toggleSilence()
        results["output_previous_level_restored"] = abs(output.fraction - 0.23) < 0.00001
        results["no_capture_started"] = model.phase == .idle && model.duration == 0 && model.lastRecording == nil
        output.requestVolume(original)
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("output-independence-tests.json"))
        }
    }

    static func run(window: NSWindow, model: CaptureModel, folder: URL) async {
        var results = [String: Bool]()
        window.makeKeyAndOrderFront(nil)
        guard let view = window.contentView else { return }
        func point(_ x: Double, _ topY: Double) -> CGPoint {
            view.convert(CGPoint(x: x, y: view.isFlipped ? topY : view.bounds.height - topY), to: nil)
        }
        func events(_ locations: [CGPoint]) {
            let now = ProcessInfo.processInfo.systemUptime
            for (index, location) in locations.enumerated() {
                let type: NSEvent.EventType = index == 0 ? .leftMouseDown : index == locations.count - 1 ? .leftMouseUp : .leftMouseDragged
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: now + Double(index) * 0.02, windowNumber: window.windowNumber,
                    context: nil, eventNumber: index, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        func pause() async { try? await Task.sleep(nanoseconds: 300_000_000) }
        func drag(_ locations: [CGPoint]) async {
            // Let SwiftUI update gesture/layout state between pointer events,
            // rather than relying on a batch of coalescible synthetic events.
            for (index, location) in locations.enumerated() {
                let type: NSEvent.EventType = index == 0 ? .leftMouseDown : index == locations.count - 1 ? .leftMouseUp : .leftMouseDragged
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: index, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            await pause()
        }
        func click(_ x: Double, _ y: Double) async {
            events([point(x, y), point(x, y)])
            await pause()
        }
        let source = model.graph.nodes[0].id
        let gain = model.graph.nodes[1].id
        let recorder = model.graph.nodes[2].id
        // The native toolbar is 41 pt high; the default ports sit at canvas y = 112.
        await click(154, 153)
        await click(446, 153)
        results["click_connect_bypasses_gain"] = model.route?.nodes.map(\.id) == [source, recorder]
        await click(154, 153)
        await click(236, 153)
        results["incomplete_route_blocks_recording"] = model.route == nil
        await click(364, 153)
        await click(446, 153)
        results["click_connect_restores_chain"] = model.route?.nodes.map(\.id) == [source, gain, recorder]
        await drag([point(300, 153), point(300, 163), point(300, 173), point(300, 183), point(300, 193), point(300, 193)])
        results["node_drag_changes_position"] = abs((model.graph.nodes.first { $0.id == gain }?.y ?? 0) - 152) < 3
        if let position = model.graph.nodes.first(where: { $0.id == gain }),
           let data = try? JSONSerialization.data(withJSONObject: ["x": position.x, "y": position.y], options: [.prettyPrinted]) {
            try? data.write(to: folder.appendingPathComponent("node-drag-trace.json"))
        }
        await drag([point(154, 153), point(180, 130), point(250, 110), point(350, 130), point(446, 153), point(446, 153)])
        results["drag_connect_bypasses_gain"] = model.route?.nodes.map(\.id) == [source, recorder]
        results["never_started_capture"] = model.phase == .idle && model.duration == 0 && model.lastRecording == nil
        model.resetGraph()
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("ui-tests.json"))
        }
    }
}

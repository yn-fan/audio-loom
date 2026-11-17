import AppKit
import AVFoundation
import Foundation

/// Opt-in QA on the non-persisting preview model. Never adjusts real hardware.
@MainActor
enum FaderUITests {
    static func run(view: NSView, model: CaptureModel, output: OutputVolumeModel, folder: URL) async {
        precondition(output.isPreviewMode)
        var checks: [String: Bool] = [:]
        func find(_ name: String, in view: NSView) -> ConsoleFaderSlider? {
            if let slider = view as? ConsoleFaderSlider, slider.identifier?.rawValue == name { return slider }
            for child in view.subviews { if let match = find(name, in: child) { return match } }
            return nil
        }
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("fader-ui-tests.json"))
            }
        }
        guard let record = find("record-fader", in: view),
              let playback = find("output-fader", in: view),
              let window = view.window, let gain = model.quickGainNode else {
            checks["native_faders_found"] = false
            save()
            return
        }
        checks["native_faders_found"] = true
        checks["vertical_with_distinct_ranges"] = record.isVertical && playback.isVertical && record.maxValue == 2 && playback.maxValue == 1
        checks["no_blue_focus_rings"] = record.focusRingType == .none && playback.focusRingType == .none
        let initialOutput = output.fraction
        let initialGain = Double(gain.gain)
        func pause() async { try? await Task.sleep(nanoseconds: 200_000_000) }
        func drag(_ slider: ConsoleFaderSlider, to end: NSPoint, grabOffset: CGFloat = 0, modifiers: NSEvent.ModifierFlags = []) async {
            var start = slider.point(for: slider.doubleValue)
            start.y += grabOffset
            let points = (0...6).map { index -> NSPoint in
                let progress = CGFloat(index) / 6
                return slider.convert(NSPoint(x: start.x + (end.x - start.x) * progress,
                                              y: start.y + (end.y - start.y) * progress), to: nil)
            }
            let all = points + [points.last!]
            for (index, point) in all.enumerated() {
                let type: NSEvent.EventType = index == 0 ? .leftMouseDown : index == all.count - 1 ? .leftMouseUp : .leftMouseDragged
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: index, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            await pause()
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        await pause()
        let beforeRecordActions = record.actionCount
        let beforeOutputActions = playback.actionCount
        model.setGain(gain.id, value: 0.6)
        output.requestVolume(0.4)
        await pause()
        checks["readback_redraw_does_not_send_actions"] = record.actionCount == beforeRecordActions && playback.actionCount == beforeOutputActions
        checks["bindings_redraw_positions"] = abs(record.doubleValue - 0.6) < 0.001 && abs(playback.doubleValue - 0.4) < 0.001

        await drag(record, to: record.point(for: 1.5))
        checks["record_drag_changes_record_gain"] = abs(Double(model.quickGainNode?.gain ?? 0) - 1.5) < 0.015
        checks["mouse_focus_has_no_keyboard_outline"] = !record.indicatesKeyboardFocus
        checks["record_drag_leaves_output_alone"] = abs(output.fraction - 0.4) < 0.001
        var offCenter = record.point(for: record.doubleValue)
        offCenter.y += 6
        await drag(record, to: offCenter, grabOffset: 6)
        checks["grabbing_cap_edge_does_not_jump"] = abs(Double(model.quickGainNode?.gain ?? 0) - 1.5) < 0.015
        await drag(record, to: record.point(for: 2), modifiers: .option)
        checks["option_drag_is_finer"] = abs(Double(model.quickGainNode?.gain ?? 0) - 1.55) < 0.015
        model.setGain(gain.id, value: 1.5)
        await pause()
        checks["accessible_percentage_description"] = record.accessibilityValueDescription() == "150%"
        await drag(playback, to: playback.point(for: 0.3))
        checks["output_drag_changes_output"] = abs(output.fraction - 0.3) < 0.015
        checks["output_drag_leaves_record_gain_alone"] = abs(Double(model.quickGainNode?.gain ?? 0) - 1.5) < 0.015

        window.makeFirstResponder(playback)
        let beforeKey = output.fraction
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        await pause()
        checks["arrow_key_fine_adjustment"] = abs(output.fraction - beforeKey - 0.01) < 0.001
        checks["keyboard_focus_still_has_neutral_cue"] = playback.indicatesKeyboardFocus
        let beforeAccessibility = output.fraction
        let acted = playback.accessibilityPerformDecrement()
        await pause()
        checks["accessibility_adjustment"] = acted && abs(output.fraction - beforeAccessibility + 0.01) < 0.001
        await drag(playback, to: NSPoint(x: 39, y: -100))
        checks["top_boundary_clamped"] = output.fraction == 1
        await drag(playback, to: NSPoint(x: 39, y: 300))
        checks["bottom_boundary_clamped"] = output.fraction == 0
        checks["mouse_drag_clears_keyboard_cue"] = !playback.indicatesKeyboardFocus

        model.setMuted(true)
        await pause()
        let beforeDisabled = model.quickGainNode?.gain
        checks["disabled_fader_cannot_change_volume"] = !record.isEnabled && !record.accessibilityPerformIncrement() && model.quickGainNode?.gain == beforeDisabled
        model.setMuted(false)
        model.setGain(gain.id, value: initialGain)
        output.requestVolume(initialOutput)
        await pause()
        checks["no_capture_started"] = model.phase == .idle && model.duration == 0 && model.lastRecording == nil
        checks["preview_hardware_only"] = output.isPreviewMode
        save()
    }

    static func showSyntheticSignal(model: CaptureModel, folder: URL) {
        var checks: [String: Bool] = [:]
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
            buffer.frameLength = 96_000
            for frame in 0..<96_000 {
                let time = Double(frame) / 48_000
                buffer.floatChannelData![0][frame] = Float((0.08 + 0.8 * abs(sin(time * 5.2))) * sin(2 * .pi * 220 * time))
                buffer.floatChannelData![1][frame] = Float((0.08 + 0.36 * abs(sin(time * 3.7))) * sin(2 * .pi * 330 * time))
            }
            try model.setSyntheticVisualization(buffer)
            checks["actual_sample_envelope_visible"] = model.hasAudioVisualization && model.waveform.contains { $0.maximum > 0.6 && $0.minimum < -0.6 }
            checks["separate_channel_levels"] = model.peaks.count == 2 && model.peaks[0] > model.peaks[1] && model.peaks[1] > 0.3
            checks["preview_clearly_identified"] = model.visualizationIsSynthetic
            checks["no_recording_or_capture"] = model.phase == .idle && model.duration == 0 && model.lastRecording == nil
        } catch { checks["synthetic_signal_preparation"] = false }
        if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("visualization-ui-tests.json"))
        }
    }
}

import AppKit
import Foundation

/// Checks the transport layout and source-selector hit area using only our own
/// views and a non-capturing preview model.
@MainActor
enum DeckUITests {
    static func run(view: NSView, model: CaptureModel, folder: URL) async {
        var checks: [String: Bool] = [:]
        func find(_ name: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == name { return view }
            for child in view.subviews { if let match = find(name, in: child) { return match } }
            return nil
        }
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("deck-ui-tests.json"))
            }
        }
        guard let source = find("source-menu-anchor", in: view),
              let clock = find("clock-display-anchor", in: view),
              let record = find("record-control-anchor", in: view),
              let window = view.window else {
            checks["transport_components_found"] = false
            save()
            return
        }
        let sourceRect = source.convert(source.bounds, to: view)
        let clockRect = clock.convert(clock.bounds, to: view)
        let recordRect = record.convert(record.bounds, to: view)
        checks["source_target_is_larger"] = sourceRect.width >= 148 && sourceRect.height >= 54
        checks["source_left_of_time_left_of_record"] = sourceRect.maxX <= clockRect.minX && clockRect.maxX <= recordRect.minX
        checks["transport_is_one_aligned_row"] = abs(sourceRect.midY - clockRect.midY) < 1 && abs(clockRect.midY - recordRect.midY) < 1
        checks["all_transport_controls_fit"] = [sourceRect, clockRect, recordRect].allSatisfy {
            $0.minX >= 0 && $0.maxX <= view.bounds.width + 0.5 && $0.minY >= 0 && $0.maxY <= view.bounds.height + 0.5
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let original = model.selectedSource
        // The click lands on the vinyl itself, not just the source-name text.
        let point = source.convert(NSPoint(x: 18, y: source.bounds.midY), to: nil)
        func select(_ title: String) async {
            NativeMenuTestTrace.requestedTitle = title
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        await select("系统声音")
        if let app = model.sources.first {
            await select(app.name)
            checks["vinyl_hit_area_selects_a_source"] = model.selectedSource == app.id
        } else {
            checks["vinyl_hit_area_selects_a_source"] = NativeMenuTestTrace.events.contains { $0.hasPrefix("opened: 系统声音") }
        }
        await select("系统声音")
        checks["source_can_return_to_system_audio"] = model.selectedSource == 0
        model.selectedSource = original
        checks["selection_does_not_record"] = model.phase == .idle && model.duration == 0 && model.lastRecording == nil
        save()
    }
}

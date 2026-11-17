import AppKit
import SwiftUI

/// NSSlider retains native focus and accessibility semantics; the travel,
/// rectangular cap and markings use a compact console-style presentation.
final class ConsoleFaderSlider: NSSlider {
    var unityMarker: Double?
    var levelPeaks: [Float]?
    private(set) var actionCount = 0
    private(set) var indicatesKeyboardFocus = false
    private var focusingFromMouse = false
    private var isTrackingDrag = false
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 96, height: 132) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        indicatesKeyboardFocus = result && !focusingFromMouse
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { indicatesKeyboardFocus = false; needsDisplay = true }
        return result
    }

    var trackTop: CGFloat { 12 }
    var trackBottom: CGFloat { max(13, bounds.height - 24) }
    private var trackX: CGFloat { 39 }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    func point(for value: Double) -> NSPoint {
        let fraction = maxValue > minValue ? min(1, max(0, (value - minValue) / (maxValue - minValue))) : 0
        return NSPoint(x: trackX, y: trackBottom - CGFloat(fraction) * (trackBottom - trackTop))
    }

    private var capRect: NSRect {
        let center = point(for: doubleValue)
        return NSRect(x: center.x - 16, y: center.y - 10, width: 32, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.35)
        let track = NSRect(x: trackX - 3, y: trackTop, width: 6, height: trackBottom - trackTop)
        NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(isDark ? 0.08 : 0.5).setStroke()
        let rim = NSBezierPath()
        rim.move(to: NSPoint(x: track.maxX + 0.7, y: track.minY + 2))
        rim.line(to: NSPoint(x: track.maxX + 0.7, y: track.maxY - 2))
        rim.lineWidth = 0.65
        rim.stroke()

        drawScale()
        if let levelPeaks {
            // Meters remain readable if the gain module is bypassed/disabled.
            NSGraphicsContext.current?.cgContext.setAlpha(1)
            drawMeters(levelPeaks)
            NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.35)
        }
        drawCap()
    }

    private func drawScale() {
        for index in 0...8 {
            let fraction = Double(index) / 8
            let value = minValue + fraction * (maxValue - minValue)
            let y = point(for: value).y
            let major = index.isMultiple(of: 2)
            let unity = unityMarker.map { abs($0 - value) < 0.0001 } ?? false
            (unity ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: 59, y: y))
            tick.line(to: NSPoint(x: major ? 66 : 63, y: y))
            tick.lineWidth = unity ? 1.1 : 0.7
            tick.stroke()
            if index.isMultiple(of: 4) {
                let label = "\(Int((value * 100).rounded()))" as NSString
                label.draw(at: NSPoint(x: 69, y: y - 7), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: unity ? .medium : .regular),
                    .foregroundColor: unity ? NSColor.labelColor.withAlphaComponent(0.8) : NSColor.secondaryLabelColor
                ])
            }
        }
    }

    private func drawMeters(_ values: [Float]) {
        let count = 18
        let gap: CGFloat = 1.3
        let cellHeight = (trackBottom - trackTop - CGFloat(count - 1) * gap) / CGFloat(count)
        for channel in 0..<2 {
            let peak = channel < values.count && values[channel].isFinite ? max(0, values[channel]) : 0
            let normalized = peak > 0 ? min(1, max(0, (20 * log10(Double(peak)) + 60) / 60)) : 0
            let litCount = Int(ceil(normalized * Double(count)))
            for index in 0..<count {
                let rect = NSRect(x: CGFloat(4 + channel * 7),
                                  y: trackBottom - CGFloat(index + 1) * cellHeight - CGFloat(index) * gap,
                                  width: 3.5, height: cellHeight)
                let color: NSColor
                if index >= litCount {
                    color = NSColor.labelColor.withAlphaComponent(0.08)
                } else if index >= count - 2 {
                    color = .systemRed
                } else if index >= count - 5 {
                    color = .systemOrange
                } else {
                    color = .systemGreen
                }
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8).fill()
            }
            (channel == 0 ? "L" : "R").draw(at: NSPoint(x: CGFloat(2 + channel * 7), y: trackBottom + 6),
                                          withAttributes: [.font: NSFont.systemFont(ofSize: 8),
                                                           .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    private func drawCap() {
        let rect = capRect
        let path = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.5 : 0.22)
        shadow.shadowBlurRadius = isTrackingDrag ? 1 : 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -1.2)
        shadow.set()
        NSColor(calibratedWhite: isDark ? 0.55 : 0.85, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let colors: [NSColor] = isDark
            ? [NSColor(white: 0.77, alpha: 1), NSColor(white: 0.62, alpha: 1), NSColor(white: 0.45, alpha: 1)]
            : [NSColor(white: 0.99, alpha: 1), NSColor(white: 0.91, alpha: 1), NSColor(white: 0.77, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: path, angle: -90)
        NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.23).setStroke()
        path.lineWidth = 0.65
        path.stroke()
        for offset in [-4.0, 0, 4] {
            let y = rect.midY + offset
            let groove = NSBezierPath()
            groove.move(to: NSPoint(x: rect.minX + 6, y: y))
            groove.line(to: NSPoint(x: rect.maxX - 6, y: y))
            NSColor.black.withAlphaComponent(offset == 0 ? 0.5 : 0.17).setStroke()
            groove.lineWidth = offset == 0 ? 1.1 : 0.65
            groove.stroke()
            if offset != 0 {
                let glint = NSBezierPath()
                glint.move(to: NSPoint(x: rect.minX + 6, y: y + 0.8))
                glint.line(to: NSPoint(x: rect.maxX - 6, y: y + 0.8))
                NSColor.white.withAlphaComponent(0.55).setStroke()
                glint.lineWidth = 0.65
                glint.stroke()
            }
        }
        if indicatesKeyboardFocus, window?.firstResponder === self {
            let cue = NSBezierPath()
            cue.move(to: NSPoint(x: rect.minX + 5, y: rect.maxY + 3))
            cue.line(to: NSPoint(x: rect.maxX - 5, y: rect.maxY + 3))
            cue.lineWidth = 1.4
            cue.lineCapStyle = .round
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            cue.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        indicatesKeyboardFocus = false
        focusingFromMouse = true
        window.makeFirstResponder(self)
        focusingFromMouse = false
        isTrackingDrag = true
        needsDisplay = true
        defer { isTrackingDrag = false; needsDisplay = true }
        let start = convert(event.locationInWindow, from: nil)
        let initialValue = doubleValue
        let onCap = capRect.insetBy(dx: -5, dy: -4).contains(start)
        let grabOffset = onCap ? start.y - capRect.midY : 0
        let fine = event.modifierFlags.contains(.option) && onCap
        func update(_ location: NSPoint) {
            let local = convert(location, from: nil)
            let value: Double
            if fine {
                value = initialValue + Double(start.y - local.y) / Double(trackBottom - trackTop) * (maxValue - minValue) * 0.1
            } else {
                let fraction = Double(trackBottom - (local.y - grabOffset)) / Double(trackBottom - trackTop)
                value = minValue + fraction * (maxValue - minValue)
            }
            _ = emit(value)
        }
        if !onCap { update(event.locationInWindow) }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            update(next.locationInWindow)
            if next.type == .leftMouseUp { break }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        indicatesKeyboardFocus = true
        needsDisplay = true
        let step = event.modifierFlags.contains(.option) ? 0.001 : 0.01
        switch event.keyCode {
        case 126, 124: _ = emit(doubleValue + step)
        case 125, 123: _ = emit(doubleValue - step)
        case 115: _ = emit(minValue)
        case 119: _ = emit(maxValue)
        default: super.keyDown(with: event)
        }
    }

    // Scrolling the popover must not accidentally change speaker volume.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func accessibilityPerformIncrement() -> Bool {
        indicatesKeyboardFocus = true
        return emit(doubleValue + 0.01)
    }
    override func accessibilityPerformDecrement() -> Bool {
        indicatesKeyboardFocus = true
        return emit(doubleValue - 0.01)
    }
    override func accessibilityValueDescription() -> String? { "\(Int((doubleValue * 100).rounded()))%" }

    @discardableResult
    private func emit(_ proposed: Double) -> Bool {
        guard isEnabled, proposed.isFinite else { return false }
        let value = min(maxValue, max(minValue, proposed))
        guard abs(value - doubleValue) > 0.0000001 else { return false }
        doubleValue = value
        needsDisplay = true
        actionCount += 1
        return sendAction(action, to: target)
    }

}

struct ConsoleFader: NSViewRepresentable {
    @Binding var value: Double
    let maximum: Double
    let identifier: String
    let label: String
    var unityMarker: Double?
    var peaks: [Float]?
    @Environment(\.isEnabled) private var isEnabled

    @MainActor
    final class Coordinator: NSObject {
        var binding: Binding<Double>
        init(_ binding: Binding<Double>) { self.binding = binding }
        @objc func changed(_ sender: NSSlider) { binding.wrappedValue = sender.doubleValue }
    }

    func makeCoordinator() -> Coordinator { Coordinator($value) }
    func makeNSView(context: Context) -> ConsoleFaderSlider {
        let slider = ConsoleFaderSlider(frame: NSRect(x: 0, y: 0, width: 96, height: 132))
        slider.isVertical = true
        slider.isContinuous = true
        slider.focusRingType = .none
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.identifier = NSUserInterfaceItemIdentifier(identifier)
        slider.setAccessibilityLabel(label)
        return slider
    }

    func updateNSView(_ slider: ConsoleFaderSlider, context: Context) {
        context.coordinator.binding = $value
        slider.minValue = 0
        slider.maxValue = maximum
        // Updating visuals/readback NEVER sends a target-action event.
        slider.doubleValue = value.isFinite ? min(maximum, max(0, value)) : 0
        slider.unityMarker = unityMarker
        slider.levelPeaks = peaks
        if let peaks {
            let levels = (0..<2).map { channel -> String in
                guard channel < peaks.count, peaks[channel].isFinite, peaks[channel] > 0 else { return "静音" }
                return "\(Int((20 * log10(Double(peaks[channel]))).rounded())) dBFS"
            }
            slider.setAccessibilityHelp("实际录音峰值：左声道 \(levels[0])，右声道 \(levels[1])。方向键每次调整 1%；Option 拖动更精细。")
        } else {
            slider.setAccessibilityHelp("独立外放音量。方向键每次调整 1%；不会改变录音增益。")
        }
        slider.isEnabled = isEnabled
        slider.needsDisplay = true
    }
}

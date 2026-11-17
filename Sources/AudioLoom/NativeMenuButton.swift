import AppKit
import SwiftUI

struct NativeMenuEntry {
    let title: String
    var selected = false
    var action: (() -> Void)?

    static var separator: NativeMenuEntry { NativeMenuEntry(title: "") }
}

@MainActor
enum NativeMenuTestTrace {
    static var events: [String] = []
    static var requestedTitle: String?
}

@MainActor
private final class MenuAnchorHolder: ObservableObject {
    weak var view: NSView?
}

private final class MenuAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Non-interactive geometry marker for checking a native layout without screen
/// scraping or accessibility permissions. It never consumes pointer events.
struct LayoutMarker: NSViewRepresentable {
    let identifier: String
    func makeNSView(context: Context) -> NSView {
        let view = MenuAnchorView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct MenuAnchor: NSViewRepresentable {
    let holder: MenuAnchorHolder
    let identifier: String?
    func makeNSView(context: Context) -> NSView {
        let view = MenuAnchorView()
        if let identifier { view.identifier = NSUserInterfaceItemIdentifier(identifier) }
        holder.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class MenuActionTarget: NSObject {
    let entries: [NativeMenuEntry]
    init(entries: [NativeMenuEntry]) { self.entries = entries }
    @objc func selectEntry(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag) else { return }
        if CommandLine.arguments.contains("--exercise-ui") {
            NativeMenuTestTrace.events.append("selected: \(sender.tag) \(sender.title)")
        }
        entries[sender.tag].action?()
    }
}

/// Keeps the designed SwiftUI label intact while presenting a real native NSMenu.
/// SwiftUI's borderless Menu on this SDK flattens multi-line labels into a title.
struct NativeMenuButton<Label: View>: View {
    let entries: [NativeMenuEntry]
    var identifier: String? = nil
    @ViewBuilder let label: () -> Label
    @StateObject private var anchor = MenuAnchorHolder()
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: showMenu, label: label)
            .buttonStyle(.plain)
            .focused($focused)
            .focusEffectDisabled()
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(focused ? 0.45 : 0))
                    .frame(height: 1).padding(.horizontal, 6).allowsHitTesting(false)
            }
            .background(MenuAnchor(holder: anchor, identifier: identifier))
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        if CommandLine.arguments.contains("--exercise-ui") {
            NativeMenuTestTrace.events.append("opened: \(entries.map(\.title).joined(separator: " | "))")
        }
        let target = MenuActionTarget(entries: entries)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, entry) in entries.enumerated() {
            if entry.title.isEmpty {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(MenuActionTarget.selectEntry(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            item.isEnabled = entry.action != nil
            item.state = entry.selected ? .on : .off
            menu.addItem(item)
        }
        // NSMenu's private tracking loop does not reliably consume synthetic
        // type-ahead events. QA clicks the real button, then dispatches the same
        // native menu-item action a mouse selection invokes. Normal runs never
        // enter this path, and the preview model does not persist preferences.
        if CommandLine.arguments.contains("--snapshot-directory"),
           CommandLine.arguments.contains("--exercise-ui"),
           let title = NativeMenuTestTrace.requestedTitle,
           let index = menu.items.firstIndex(where: { $0.title == title }) {
            NativeMenuTestTrace.requestedTitle = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                menu.performActionForItem(at: index)
                menu.cancelTracking()
            }
        }
        withExtendedLifetime(target) {
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        }
    }
}

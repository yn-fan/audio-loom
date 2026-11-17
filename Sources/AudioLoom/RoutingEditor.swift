import AudioCore
import SwiftUI

struct RoutingEditor: View {
    @ObservedObject var model: CaptureModel
    @State private var selectedNode: UUID?
    @State private var selectedEdge: AudioConnection?
    @State private var pendingOutput: UUID?
    @State private var wireEnd: CGPoint?
    @State private var offsets: [UUID: CGSize] = [:]
    @State private var error: String?
    @State private var resetConfirmation = false
    @FocusState private var canvasFocused: Bool
    private let nodeWidth = 128.0
    private let nodeHeight = 76.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pendingOutput == nil ? "拖动模块，连接声音路径。" : "点选目标模块左侧的圆点。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("音量") { add(.gain) }
                    Button("单声道") { add(.mono) }
                } label: { Label("添加", systemImage: "plus") }
                    .fixedSize().disabled(model.isActive || model.graph.nodes.count >= 12)
                Button("还原") { resetConfirmation = true }.disabled(model.isActive)
            }
            .controlSize(.small).padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    canvas.frame(
                        width: max(viewport.size.width, (model.graph.nodes.map(\.x).max() ?? 510) + 90),
                        height: max(viewport.size.height, (model.graph.nodes.map(\.y).max() ?? 112) + 60)
                    )
                }
            }
            Divider()
            inspector.padding(.horizontal, 16).frame(height: 65)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: model.isActive ? "lock" : model.route == nil ? "exclamationmark.circle" : "checkmark.circle")
                Text(error ?? (model.isActive ? "录音中；停止后可修改连线。" : model.routeError ?? "已连接 · 按连线顺序处理声音"))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle((error != nil || model.route == nil) ? Color.orange : .secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 600, idealWidth: 620, minHeight: 360, idealHeight: 400)
        .onAppear { selectedNode = model.quickGainNode?.id }
        .alert("还原默认流程？", isPresented: $resetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("还原") {
                model.resetGraph()
                selectedNode = model.quickGainNode?.id
                selectedEdge = nil; pendingOutput = nil; error = nil
            }
        } message: { Text("将替换当前模块和连线，恢复为「音源 → 音量 → 录音」。") }
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor).opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { selectedNode = nil; selectedEdge = nil; pendingOutput = nil; error = nil; canvasFocused = true }
            ForEach(model.graph.connections) { edge in
                if let from = model.graph.nodes.first(where: { $0.id == edge.from }),
                   let to = model.graph.nodes.first(where: { $0.id == edge.to }) {
                    let path = cable(from: portPosition(from, output: true), to: portPosition(to, output: false))
                    path.stroke(selectedEdge == edge ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.55),
                                style: StrokeStyle(lineWidth: selectedEdge == edge ? 2.5 : 1.5, lineCap: .round))
                        .allowsHitTesting(false)
                    path.stroke(Color.primary.opacity(0.001), lineWidth: 14)
                        .onTapGesture {
                            selectedEdge = edge; selectedNode = nil; pendingOutput = nil; canvasFocused = true
                        }
                        .contextMenu {
                            Button("断开连接") { model.disconnect(edge); selectedEdge = nil }.disabled(model.isActive)
                        }
                        .accessibilityLabel("\(from.kind.title)到\(to.kind.title)的连线")
                }
            }
            if let pendingOutput, let node = model.graph.nodes.first(where: { $0.id == pendingOutput }) {
                let start = portPosition(node, output: true)
                cable(from: start, to: wireEnd ?? CGPoint(x: start.x + 70, y: start.y))
                    .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .allowsHitTesting(false)
            }
            ForEach(model.graph.nodes) { node in
                nodeView(node)
                    .position(x: node.x + (offsets[node.id]?.width ?? 0),
                              y: node.y + (offsets[node.id]?.height ?? 0))
            }
        }
        .coordinateSpace(name: "graph")
        .focusable().focusEffectDisabled().focused($canvasFocused)
        .onDeleteCommand { deleteSelection() }
        .onExitCommand { pendingOutput = nil; wireEnd = nil; selectedEdge = nil; error = nil }
    }

    private func nodeView(_ node: AudioNode) -> some View {
        ZStack {
            VStack(spacing: 8) {
                Label(node.kind.title, systemImage: node.kind.symbol).font(.system(size: 12, weight: .medium))
                Text(subtitle(node)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: nodeWidth, height: nodeHeight)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selectedNode == node.id ? Color.primary.opacity(0.6) : Color(nsColor: .separatorColor),
                        lineWidth: selectedNode == node.id ? 1.5 : 0.75))
            .opacity(node.bypassed ? 0.65 : 1)
            .contentShape(Rectangle())
            .onTapGesture { selectedNode = node.id; selectedEdge = nil; canvasFocused = true }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("graph"))
                .onChanged {
                    guard !model.isActive else { return }
                    selectedNode = node.id; selectedEdge = nil; offsets[node.id] = $0.translation
                }
                .onEnded {
                    model.moveNode(node.id, x: node.x + $0.translation.width, y: node.y + $0.translation.height)
                    offsets[node.id] = nil
                })
            .contextMenu {
                if node.kind.isProcessor {
                    Button(node.bypassed ? "启用模块" : "旁通模块") { model.setBypassed(node.id, value: !node.bypassed) }
                    Button("移除模块") { model.removeNode(node.id); selectedNode = nil }.disabled(model.isActive)
                }
            }
            if node.kind != .source {
                Button { connect(to: node.id) } label: { port(isPending: pendingOutput != nil) }
                    .buttonStyle(.plain).frame(width: 24, height: 32)
                    .disabled(model.isActive).help("输入：点击以连接")
                    .accessibilityLabel("\(node.kind.title)输入端")
                    .offset(x: -nodeWidth / 2)
            }
            if node.kind != .recorder {
                Button {
                    pendingOutput = pendingOutput == node.id ? nil : node.id
                    selectedEdge = nil; error = nil
                } label: { port(isPending: pendingOutput == node.id) }
                    .buttonStyle(.plain).frame(width: 24, height: 32)
                    .disabled(model.isActive).help("输出：拖到或点选另一个模块的输入端")
                    .accessibilityLabel("\(node.kind.title)输出端")
                    .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("graph"))
                        .onChanged {
                            guard !model.isActive else { return }
                            pendingOutput = node.id; wireEnd = $0.location; error = nil
                        }
                        .onEnded { value in
                            guard !model.isActive else { return }
                            if let target = model.graph.nodes.first(where: {
                                $0.kind != .source && $0.id != node.id
                                && hypot(portPosition($0, output: false).x - value.location.x,
                                         portPosition($0, output: false).y - value.location.y) < 26
                            }) { connect(to: target.id) }
                            wireEnd = nil
                        })
                    // Move the entire interactive port, not just its drawing.
                    // Otherwise its outer drag gesture can cover the node center.
                    .offset(x: nodeWidth / 2)
            }
        }
        .frame(width: nodeWidth, height: nodeHeight)
    }

    private func port(isPending: Bool) -> some View {
        Circle().fill(Color(nsColor: .controlBackgroundColor))
            .overlay(Circle().stroke(isPending ? Color.primary.opacity(0.75) : Color.secondary, lineWidth: 1.5))
            .frame(width: 10, height: 10).frame(width: 24, height: 32).contentShape(Rectangle())
    }

    private func subtitle(_ node: AudioNode) -> String {
        if node.bypassed { return "已旁通" }
        switch node.kind {
        case .source: return model.sourceName
        case .gain: return "\(Int((node.gain * 100).rounded()))%"
        case .mono: return "左右声道合并"
        case .recorder: return node.muted ? "静音写入" : "\(model.outputFormat.title) · 48 kHz"
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let id = selectedNode, let node = model.graph.nodes.first(where: { $0.id == id }) {
            HStack(spacing: 14) {
                Label(node.kind.title, systemImage: node.kind.symbol).font(.system(size: 12, weight: .medium))
                if node.kind == .gain {
                    Slider(value: Binding(get: { Double(model.graph.nodes.first { $0.id == id }?.gain ?? 1) },
                                          set: { model.setGain(id, value: $0) }), in: 0...2)
                        .frame(maxWidth: 170).disabled(node.bypassed).accessibilityLabel("所选音量模块")
                    Text("\(Int((node.gain * 100).rounded()))%").monospacedDigit().frame(width: 38)
                } else if node.kind == .source {
                    Picker("音源", selection: $model.selectedSource) {
                        Text("系统声音").tag(Int32(0))
                        ForEach(model.sources) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 220).disabled(model.isActive)
                } else if node.kind == .recorder {
                    Picker("格式", selection: Binding(get: { model.outputFormat }, set: { model.setOutputFormat($0) })) {
                        ForEach(RecordingFormat.allCases) { Text($0.title).tag($0) }
                    }.frame(width: 140).disabled(model.isActive).help(model.outputFormat.detail)
                    Toggle("静音写入", isOn: Binding(get: { model.muted }, set: { model.setMuted($0) }))
                        .toggleStyle(.checkbox)
                } else {
                    Text("两声道平均后写入左右声道。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if node.kind.isProcessor {
                    Toggle("启用", isOn: Binding(get: { !node.bypassed }, set: { model.setBypassed(id, value: !$0) }))
                        .toggleStyle(.checkbox)
                    Button("移除") { model.removeNode(id); selectedNode = nil }.disabled(model.isActive)
                }
            }.font(.system(size: 12)).controlSize(.small)
        } else if let selectedEdge {
            HStack {
                Text("这条连线决定音频从哪个模块进入下一个模块。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("断开连接") { model.disconnect(selectedEdge); self.selectedEdge = nil }
                    .controlSize(.small).disabled(model.isActive)
            }
        } else {
            HStack {
                Image(systemName: "cursorarrow").foregroundStyle(.secondary)
                Text("拖拽连接，或先点输出圆点，再点输入圆点。新连线会替换端口原有连线。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func portPosition(_ node: AudioNode, output: Bool) -> CGPoint {
        CGPoint(x: node.x + (offsets[node.id]?.width ?? 0) + (output ? nodeWidth / 2 : -nodeWidth / 2),
                y: node.y + (offsets[node.id]?.height ?? 0))
    }

    private func cable(from: CGPoint, to: CGPoint) -> Path {
        Path {
            $0.move(to: from)
            let bend = max(40, abs(to.x - from.x) * 0.5)
            // A long bypass wire goes above intermediate modules, not behind their ports.
            if to.x - from.x > 180 && abs(to.y - from.y) < 36 {
                let top = max(12, min(from.y, to.y) - 100)
                $0.addCurve(to: to, control1: CGPoint(x: from.x + bend * 0.5, y: top),
                            control2: CGPoint(x: to.x - bend * 0.5, y: top))
            } else {
                $0.addCurve(to: to, control1: CGPoint(x: from.x + bend, y: from.y),
                            control2: CGPoint(x: to.x - bend, y: to.y))
            }
        }
    }

    private func connect(to target: UUID) {
        guard let source = pendingOutput else { error = "请先点击一个模块右侧的输出圆点。"; return }
        do {
            try model.connect(from: source, to: target)
            pendingOutput = nil; wireEnd = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func add(_ kind: NodeKind) {
        do { selectedNode = try model.addNode(kind); selectedEdge = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func deleteSelection() {
        guard !model.isActive else { return }
        if let selectedEdge { model.disconnect(selectedEdge); self.selectedEdge = nil }
        else if let selectedNode {
            model.removeNode(selectedNode)
            self.selectedNode = nil
        }
    }
}

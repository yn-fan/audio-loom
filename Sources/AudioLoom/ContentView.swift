import AudioCore
import SwiftUI

/// A compact deck: source, elapsed time and transport form one hardware-like unit.
struct ContentView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var outputVolume: OutputVolumeModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var sourceHovered = false
    @FocusState private var recordFocused: Bool
    @FocusState private var folderFocused: Bool
    @FocusState private var moreFocused: Bool
    let onRecord: () -> Void
    let onEdit: () -> Void
    let onDetails: () -> Void
    let onQuit: () -> Void

    private var showsSignal: Bool { model.isActive || model.visualizationIsSynthetic }
    private var recordTitle: String {
        switch model.phase {
        case .idle: return "录音"
        case .starting: return "连接中"
        case .recording: return "停止"
        case .stopping: return "保存中"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            deckTransport
            // A fixed signal lane prevents the faders moving under the pointer.
            AudioWaveformView(model: model).opacity(showsSignal ? 1 : 0)
                .accessibilityHidden(!showsSignal).allowsHitTesting(false).padding(.top, 6)
            VolumeFaderBank(model: model, output: outputVolume).padding(.top, 8)
            if let error = model.routeError {
                Button("处理流程未接通 · 检查", action: onEdit)
                    .buttonStyle(.link).font(.system(size: 11)).help(error)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            } else if model.hasError {
                Button("录音未完成 · 查看原因", action: onDetails)
                    .buttonStyle(.link).font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            Divider().opacity(0.55).padding(.top, 10).padding(.bottom, 10)
            footer
        }
        .padding(14)
        .frame(width: 328)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.35))
                }
        }
        .font(.system(size: 12))
    }

    private var deckTransport: some View {
        HStack(spacing: 6) {
            sourcePad
            clockDisplay
            recordButton
        }
        .padding(8)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.035),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.045), lineWidth: 0.5)
        }
    }

    private var sourcePad: some View {
        NativeMenuButton(entries: sourceEntries, identifier: "source-menu-anchor") {
            HStack(spacing: 6) {
                VinylBadge()
                Text(model.sourceName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(width: 156, height: 58)
            .background(Color(nsColor: .controlBackgroundColor).opacity(sourceHovered ? 0.85 : 0.4),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .onHover { sourceHovered = $0 }
        .disabled(model.isActive).opacity(model.isActive ? 0.6 : 1)
        .help("\(model.sourceName)\n点击整块唱片区选择要录制的软件或系统声音")
        .accessibilityLabel("选择录音音源，当前为\(model.sourceName)")
    }

    private var clockDisplay: some View {
        Text(model.compactDurationText)
            .font(.system(size: model.duration >= 3600 ? 13 : 19, weight: .medium, design: .monospaced))
            .monospacedDigit().tracking(-0.3)
            .foregroundStyle(Color(white: model.phase == .recording ? 0.96 : 0.82))
            .frame(width: 74, height: 48)
            .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if model.phase == .recording && model.recordingIsSilenced {
                    Image(systemName: "speaker.slash").font(.system(size: 8)).foregroundStyle(.orange).padding(4)
                } else if model.phase == .recording && model.clipped {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 8)).foregroundStyle(.orange).padding(4)
                }
            }
            .background(LayoutMarker(identifier: "clock-display-anchor"))
            .accessibilityLabel("已写入的录音时长 \(model.durationText)")
            .help("录音时长；红色状态在菜单栏中同步显示")
    }

    private var recordButton: some View {
        Button(action: onRecord) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.65))
                        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        RoundedRectangle(cornerRadius: model.phase == .recording ? 3 : 11)
                            .fill(Color(nsColor: .systemRed))
                            .frame(width: model.phase == .recording ? 13 : 22,
                                   height: model.phase == .recording ? 13 : 22)
                    }
                }.frame(width: 36, height: 36)
                Text(recordTitle).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(width: 42, height: 58)
            .background(Color.primary.opacity(recordFocused ? 0.065 : 0),
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focused($recordFocused).focusEffectDisabled()
        .background(LayoutMarker(identifier: "record-control-anchor"))
        .disabled(model.isBusy || (model.phase == .idle && model.route == nil))
        .keyboardShortcut("r", modifiers: .command)
        .help("自动保存到下载文件夹；停止并保存成功后在 Finder 中选中文件。")
        .accessibilityLabel(model.phase == .recording ? "停止并保存录音" : "开始录音")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            NativeMenuButton(entries: formatEntries, identifier: "format-menu-anchor") {
                HStack(spacing: 4) {
                    Text(model.outputFormat.title)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                }.contentShape(Rectangle())
            }
            .fixedSize().disabled(model.isActive)
            .help(model.outputFormat.detail)
            .accessibilityLabel("保存格式：\(model.outputFormat.title)")
            Spacer(minLength: 0)
            Button { model.openRecordingFolder() } label: {
                Label("下载", systemImage: "folder").font(.system(size: 11))
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(folderFocused ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain).focused($folderFocused).focusEffectDisabled()
            .help("打开录音保存文件夹").accessibilityLabel("打开下载文件夹")
            Menu {
                Button("显示上次录音") { model.revealRecording() }.disabled(model.lastRecording == nil)
                Button("刷新音源") { model.refreshSources() }.disabled(model.isActive)
                Divider()
                Button("高级处理…", action: onEdit)
                Text("外放：\(outputVolume.deviceName)")
                Divider()
                Button("退出声流", action: onQuit).keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
                    .background(Color.primary.opacity(moreFocused ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .focused($moreFocused).focusEffectDisabled()
            .accessibilityLabel("更多操作")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 22)
    }

    private var sourceEntries: [NativeMenuEntry] {
        [NativeMenuEntry(title: "系统声音", selected: model.selectedSource == 0, action: {
            if !model.isActive { model.selectedSource = 0 }
        })]
        + model.sources.map { source in
            NativeMenuEntry(title: source.name, selected: model.selectedSource == source.id,
                            action: { if !model.isActive { model.selectedSource = source.id } })
        }
        + [.separator, NativeMenuEntry(title: "刷新应用列表", action: { model.refreshSources() })]
    }

    private var formatEntries: [NativeMenuEntry] {
        RecordingFormat.allCases.map { format in
            NativeMenuEntry(title: format.menuTitle, selected: model.outputFormat == format,
                            action: { model.setOutputFormat(format) })
        }
    }
}

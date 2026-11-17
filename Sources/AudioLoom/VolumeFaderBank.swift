import SwiftUI

struct VolumeFaderBank: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var output: OutputVolumeModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                recordingStrip.frame(maxWidth: .infinity)
                Rectangle().fill(Color.primary.opacity(0.05)).frame(width: 0.5, height: 126)
                    .padding(.horizontal, 10).padding(.top, 24)
                outputStrip.frame(maxWidth: .infinity)
            }
            if let error = output.error {
                HStack(alignment: .top, spacing: 6) {
                    Text(output.canAdjust ? "外放调整未完成" : "当前外放不可调").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).help(error)
                    Button { output.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).font(.system(size: 11)).help("重新检测外放设备")
                }
            }
        }
    }

    private var recordingStrip: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text("录音").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(model.quickGainNode.map { "\(Int(($0.gain * 100).rounded()))%" } ?? "直通")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                Spacer(minLength: 2)
                Button { model.setMuted(!model.muted) } label: {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.1")
                        .font(.system(size: 12)).frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(model.muted ? Color.orange : .secondary)
                .help(model.muted ? "取消录音静音" : "静音录音；不改变外放音量")
                .accessibilityLabel(model.muted ? "取消录音静音" : "静音录音")
            }
            .frame(height: 22)
            .help("录音音量；只影响录音文件，100% 为原始音量")
            ConsoleFader(
                value: Binding(get: { Double(model.quickGainNode?.gain ?? 1) },
                               set: { if let gain = model.quickGainNode { model.setGain(gain.id, value: $0) } }),
                maximum: 2, identifier: "record-fader", label: "录音音量，0 到 200 百分比",
                unityMarker: 1, peaks: model.isActive || model.visualizationIsSynthetic ? model.peaks : nil
            )
            .frame(width: 96, height: 132)
            .disabled(model.muted || model.quickGainNode == nil)
            .help("上下拖动推子；100% 为原始音量。方向键微调，Option 拖动更精细。左侧为实际录音的左右声道峰值。")
        }
    }

    private var outputStrip: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text("外放").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(output.percentage).font(.system(size: 12, weight: .medium)).monospacedDigit()
                Spacer(minLength: 2)
                Group {
                    if output.isApplying || output.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button { output.toggleSilence() } label: {
                            Image(systemName: output.fraction <= 0.001 ? "speaker.slash.fill" : "speaker.wave.1")
                                .font(.system(size: 12)).frame(width: 24, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(!output.canAdjust)
                        .help(output.fraction <= 0.001 ? "恢复外放音量" : "外放归零；不影响录音文件")
                        .accessibilityLabel(output.fraction <= 0.001 ? "恢复外放音量" : "外放音量降为零")
                    }
                }.frame(width: 24, height: 22)
            }.frame(height: 22)
            ConsoleFader(
                value: Binding(get: { output.fraction }, set: { output.requestVolume($0) }),
                maximum: 1, identifier: "output-fader", label: "系统外放音量，0 到 100 百分比，与录音独立"
            )
            .frame(width: 96, height: 132).disabled(!output.canAdjust)
            .help("\(output.deviceName) · 不录音也可调节，不改变录音增益")
        }
    }
}

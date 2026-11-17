import AudioCore
import SwiftUI

struct AudioWaveformView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = size.height / 2
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: center))
                axis.addLine(to: CGPoint(x: size.width, y: center))
                context.stroke(axis, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
                guard model.hasAudioVisualization else { return }
                let step = size.width / CGFloat(max(1, model.waveform.count))
                for (index, bin) in model.waveform.enumerated() {
                    let top = center - CGFloat(bin.maximum) * (center - 2)
                    let bottom = center - CGFloat(bin.minimum) * (center - 2)
                    let rect = CGRect(x: CGFloat(index) * step + step * 0.16,
                                      y: min(top, bottom), width: max(0.6, step * 0.68),
                                      height: max(0.7, abs(bottom - top)))
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.65),
                                 with: .color(model.clipped ? .orange.opacity(0.8) : .primary.opacity(0.48)))
                }
            }
            if model.visualizationIsSynthetic {
                Text("合成信号预览").font(.system(size: 9))
                    .foregroundStyle(.secondary).padding(.horizontal, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.visualizationIsSynthetic ? "合成信号预览"
                            : model.hasAudioVisualization ? "最近约两秒录音的双声道波形包络" : "尚未采集音频")
        .help("实际录音流的双声道包络；不在空闲时采集声音。")
    }
}

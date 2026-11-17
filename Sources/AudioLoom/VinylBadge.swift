import SwiftUI

/// A small, static vinyl platter. It identifies the source selector; it is not
/// an audio meter, playback control, or decorative looping animation.
struct VinylBadge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: [
                    Color(white: 0.09), Color(white: 0.20), Color(white: 0.07),
                    Color(white: 0.13), Color(white: 0.25), Color(white: 0.08)
                ], center: .center, startAngle: .degrees(12), endAngle: .degrees(372)))
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.6))
            ForEach(0..<6, id: \.self) { index in
                Circle().strokeBorder(.white.opacity(0.065), lineWidth: 0.5)
                    .padding(3 + CGFloat(index) * 1.65)
            }
            Circle().fill(Color(red: 0.82, green: 0.80, blue: 0.75)).frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 0.5))
            Circle().fill(Color(white: 0.08)).frame(width: 3.2, height: 3.2)
        }
        .frame(width: 36, height: 36)
        .shadow(color: .black.opacity(0.18), radius: 1.2, y: 1)
        .accessibilityHidden(true)
    }
}

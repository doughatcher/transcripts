import SwiftUI

/// The live EQ for the **menu-bar label**. A `MenuBarExtra` label renders its view
/// as a single template image, and layout-based views (HStack of shapes) often come
/// out blank there — so this draws the bars with `Canvas` into one bitmap, which the
/// status bar reliably shows. Bars keep a small baseline so it's never invisible.
struct MenuBarEQIcon: View {
    var levels: [Float]
    var barCount: Int = 4
    var width: CGFloat = 18
    var height: CGFloat = 15

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 2
            let bw = max(1.5, (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            let start = max(0, levels.count - barCount)
            for i in 0..<barCount {
                let idx = start + i
                let v = (idx >= 0 && idx < levels.count) ? CGFloat(levels[idx]) : 0
                let shaped = pow(max(0.08, min(1, v)), 0.6)          // baseline so it's visible
                let h = max(2.5, shaped * size.height)
                let x = CGFloat(i) * (bw + spacing)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: bw, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: bw / 2), with: .color(.primary))
            }
        }
        .frame(width: width, height: height)
    }
}

/// A live audio EQ: a row of bars whose heights follow the recent input-level
/// history (oldest → newest). Used both as the menu-bar icon while recording (so
/// you can *see* audio is arriving) and larger in the popover header.
struct LevelBarsView: View {
    /// Rolling level history in 0…1 (any length; the view samples its tail).
    var levels: [Float]
    var barCount: Int = 4
    var barWidth: CGFloat = 2.5
    var spacing: CGFloat = 1.5
    var height: CGFloat = 14
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .frame(width: barWidth, height: barHeight(at: i))
            }
        }
        .frame(height: height, alignment: .center)
        .foregroundStyle(color)
        .animation(.linear(duration: 0.07), value: levels)
    }

    private func barHeight(at index: Int) -> CGFloat {
        let start = max(0, levels.count - barCount)
        let idx = start + index
        let v = (idx >= 0 && idx < levels.count) ? CGFloat(levels[idx]) : 0
        let minH: CGFloat = 2
        // Gentle curve so quiet speech still visibly moves the bars.
        let shaped = pow(max(0, min(1, v)), 0.6)
        return minH + shaped * (height - minH)
    }
}

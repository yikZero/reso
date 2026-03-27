import SwiftUI

// MARK: - Overlay Mode

enum OverlayMode {
    case none
    case waveform
    case processing
    case success
    case error
}

// MARK: - Layout Constants

enum OverlayLayout {
    static let pillHeight: CGFloat = 36
    static let iconAreaWidth: CGFloat = 28
    static let iconTextGap: CGFloat = 6
    static let horizontalPad: CGFloat = 14
}

// MARK: - Overlay View

struct OverlayView: View {
    let statusText: String
    let accentColor: Color
    let mode: OverlayMode

    @State private var tick: Int = 0
    @State private var animationTimer: Timer?

    var body: some View {
        HStack(spacing: OverlayLayout.iconTextGap) {
            iconView
                .frame(width: OverlayLayout.iconAreaWidth, height: OverlayLayout.pillHeight - 8)

            Text(statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
        .padding(.horizontal, OverlayLayout.horizontalPad)
        .frame(height: OverlayLayout.pillHeight)
        .background(
            Capsule()
                .fill(.black.opacity(0.70))
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .onAppear { startAnimation() }
        .onDisappear { stopAnimation() }
    }

    @ViewBuilder
    private var iconView: some View {
        switch mode {
        case .waveform:
            WaveformIcon(tick: tick, color: accentColor)
        case .processing:
            ProcessingDotsIcon(tick: tick, color: accentColor)
        case .success:
            CheckmarkIcon(tick: tick, color: accentColor)
        case .error:
            CrossIcon(color: accentColor)
        case .none:
            EmptyView()
        }
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            tick += 1
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

// MARK: - Waveform

private struct WaveformIcon: View {
    let tick: Int
    let color: Color

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let barMinH: CGFloat = 3
    private let barMaxH: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
            let startX = (size.width - totalWidth) / 2

            for i in 0..<barCount {
                let phase = Double(tick) * 0.06 + Double(i) * 1.1
                let t = (sin(phase) + 1) / 2
                let height = barMinH + (barMaxH - barMinH) * t
                let alpha = 0.55 + 0.45 * t
                let x = startX + CGFloat(i) * (barWidth + barSpacing)
                let y = (size.height - height) / 2

                let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: .color(color.opacity(alpha)))
            }
        }
    }
}

// MARK: - Processing Dots

private struct ProcessingDotsIcon: View {
    let tick: Int
    let color: Color

    private let dotCount = 3
    private let dotBaseRadius: CGFloat = 2.5
    private let dotSpacing: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let totalWidth = CGFloat(dotCount - 1) * dotSpacing
            let startX = (size.width - totalWidth) / 2

            for i in 0..<dotCount {
                let phase = Double(tick) * 0.075 - Double(i) * 1.2
                let t = (sin(phase) + 1) / 2
                let radius = dotBaseRadius + 1.5 * t
                let alpha = 0.4 + 0.6 * t
                let offsetY = -3.0 * t
                let x = startX + CGFloat(i) * dotSpacing
                let y = size.height / 2 + offsetY

                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                let path = Path(ellipseIn: rect)
                context.fill(path, with: .color(color.opacity(alpha)))
            }
        }
    }
}

// MARK: - Checkmark

private struct CheckmarkIcon: View {
    let tick: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let progress = min(1.0, Double(tick) / 24.0)
            guard progress > 0 else { return }

            let cx = size.width / 2
            let cy = size.height / 2

            let p1 = CGPoint(x: cx - 6, y: cy)
            let p2 = CGPoint(x: cx - 2, y: cy + 5)
            let p3 = CGPoint(x: cx + 7, y: cy - 5)

            var path = Path()
            path.move(to: p1)

            if progress < 0.4 {
                let t = progress / 0.4
                let x = p1.x + (p2.x - p1.x) * t
                let y = p1.y + (p2.y - p1.y) * t
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: p2)
                let t = (progress - 0.4) / 0.6
                let x = p2.x + (p3.x - p2.x) * t
                let y = p2.y + (p3.y - p2.y) * t
                path.addLine(to: CGPoint(x: x, y: y))
            }

            context.stroke(path, with: .color(color), lineWidth: 2.5)
        }
    }
}

// MARK: - Cross

private struct CrossIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let r: CGFloat = 5

            var path = Path()
            path.move(to: CGPoint(x: cx - r, y: cy - r))
            path.addLine(to: CGPoint(x: cx + r, y: cy + r))
            path.move(to: CGPoint(x: cx + r, y: cy - r))
            path.addLine(to: CGPoint(x: cx - r, y: cy + r))

            context.stroke(path, with: .color(color), lineWidth: 2.5)
        }
    }
}

import DeskKeiCore
import SwiftUI

/// 1일 선차트. 가로축은 08:00~20:00 고정이고 점선은 전일 종가(기준가).
struct Sparkline: View {
    let bars: [MinuteBar]
    let prevClose: Int

    private static let regularOpen = 9 * 60
    private static let regularClose = 15 * 60 + 30
    private static let offHoursOpacity = 0.4

    var body: some View {
        Canvas { ctx, size in
            guard bars.count > 1, let last = bars.last else { return }
            let prices = bars.map(\.price) + (prevClose > 0 ? [prevClose] : [])
            let lo = Double(prices.min() ?? 0), hi = Double(prices.max() ?? 1)
            let span = max(hi - lo, 1)
            let inset: CGFloat = 3
            let width = Double(MinuteChart.endMinute - MinuteChart.startMinute)

            func point(_ minute: Int, _ price: Int) -> CGPoint {
                CGPoint(x: size.width * Double(minute - MinuteChart.startMinute) / width,
                        y: inset + (size.height - 2 * inset) * (1 - (Double(price) - lo) / span))
            }

            if prevClose > 0 {
                var base = Path()
                let y = point(MinuteChart.startMinute, prevClose).y
                base.move(to: CGPoint(x: 0, y: y))
                base.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(base, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            }

            let tint: Color = prevClose == 0 || last.price == prevClose ? .secondary : last.price > prevClose ? .up : .down
            var line = Path()
            for (i, b) in bars.enumerated() {
                let p = point(b.minute, b.price)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: point(last.minute, last.price).x, y: size.height))
            fill.addLine(to: CGPoint(x: point(bars[0].minute, bars[0].price).x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.25), tint.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // 프리장(09:00 전)·애프터(15:30 후)는 연하게, 정규장 구간만 원래 색으로 위에 덧그린다.
            ctx.stroke(line, with: .color(tint.opacity(Self.offHoursOpacity)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            var regular = Path()
            var started = false
            for b in bars where b.minute >= Self.regularOpen && b.minute <= Self.regularClose {
                let p = point(b.minute, b.price)
                if started { regular.addLine(to: p) } else { regular.move(to: p); started = true }
            }
            ctx.stroke(regular, with: .color(tint), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}

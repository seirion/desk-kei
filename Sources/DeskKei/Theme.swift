import DeskKeiCore
import SwiftUI

extension Color {
    /// 한국 증시 관례: 상승 = 빨강, 하락 = 파랑
    static let up = Color(red: 0.90, green: 0.22, blue: 0.21)
    static let down = Color(red: 0.12, green: 0.53, blue: 0.90)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
}

func color(for direction: PriceDirection) -> Color {
    switch direction {
    case .up: return .up
    case .down: return .down
    case .flat: return .primary
    }
}

func pnlColor(_ value: Int) -> Color {
    value > 0 ? .up : value < 0 ? .down : .secondary
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 3))
    }
}

struct ErrorBanner: View {
    let text: String
    var onDismiss: (() -> Void)?
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.callout)
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        .foregroundStyle(Color.up)
        .padding(8)
        .background(Color.up.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

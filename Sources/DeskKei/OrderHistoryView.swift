import DeskKeiCore
import SwiftUI

/// 당일 주문/체결 내역. 미체결 주문은 정정 화면으로 보낼 수 있다.
struct OrderHistoryView: View {
    @EnvironmentObject var model: AppModel
    let onModify: (DailyOrderItem) -> Void

    @State private var filter: CcldFilter = .all
    @State private var items: [DailyOrderItem] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(CcldFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("새로고침")
                if loading { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(10)
            Divider()

            if let error {
                Text(error).foregroundStyle(Color.up).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !loading && items.isEmpty {
                Text("내역이 없습니다.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: filter) { await load() }
    }

    private func row(_ item: DailyOrderItem) -> some View {
        let isBuy = item.side == .buy
        let tint: Color = isBuy ? .up : .down
        let executed = item.execQty > 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(isBuy ? "매수" : "매도").fontWeight(.bold).foregroundStyle(tint)
                Text(item.nameKr).fontWeight(.medium)
                Text(item.code).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(formatOrderTime(item.orderTime)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 8) {
                Text(item.orderType).font(.caption).foregroundStyle(.secondary)
                Text(quantityText(item, executed: executed, tint: tint))
                Spacer()
                Text(item.orderPrice > 0 ? "\(fmt(item.orderPrice))원" : "시장가")
                    + Text(executed && item.execAvgPrice > 0 ? " → \(fmt(Int(item.execAvgPrice.rounded())))원" : "")
                    .foregroundColor(.secondary)
            }
            .font(.callout)
            HStack {
                if executed && item.execAmount > 0 {
                    Text(item.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("체결금액 **\(fmt(item.execAmount))**원").font(.callout)
                } else {
                    Text(item.status.isEmpty ? "미체결" : item.status).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    if item.remainQty > 0 { Button("정정") { onModify(item) } }
                }
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func quantityText(_ item: DailyOrderItem, executed: Bool, tint: Color) -> AttributedString {
        var s = AttributedString("주문 \(fmt(item.orderQty))주")
        if executed {
            var e = AttributedString(" · 체결 \(fmt(item.execQty))주")
            e.foregroundColor = tint
            s += e
        }
        if item.remainQty > 0 { s += AttributedString(" · 잔여 \(fmt(item.remainQty))주") }
        return s
    }

    private func load() async {
        guard let client = model.client else {
            items = []
            error = model.account.hasCredentials ? nil : "등록된 계정이 없습니다."
            return
        }
        loading = true
        defer { loading = false }
        do {
            items = try await client.dailyOrders(filter)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

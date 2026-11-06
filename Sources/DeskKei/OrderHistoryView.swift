import DeskKeiCore
import SwiftUI

/// 당일 주문/체결 내역. 미체결 주문은 정정 화면으로 보내거나 바로 취소할 수 있다.
struct OrderHistoryView: View {
    @EnvironmentObject var model: AppModel
    let onModify: (DailyOrderItem) -> Void

    @State private var filter: CcldFilter = .all
    @State private var items: [DailyOrderItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var cancelTarget: DailyOrderItem?
    @State private var cancelingId: String?
    @State private var actionMessage: String?

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

            if let actionMessage {
                ErrorBanner(text: actionMessage) { self.actionMessage = nil }.padding(8)
            }

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
        .alert("주문 취소", isPresented: Binding(get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } })) {
            Button("주문 취소", role: .destructive) { if let t = cancelTarget { Task { await cancel(t) } } }
            Button("닫기", role: .cancel) {}
        } message: {
            if let t = cancelTarget {
                Text("[\(t.nameKr)] \(t.side == .buy ? "매수" : "매도") \(t.orderPrice > 0 ? "\(fmt(t.orderPrice))원" : "시장가") 잔여 \(fmt(t.remainQty))주를 취소하시겠습니까?")
            }
        }
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
                    emphasized("체결금액 ", fmt(item.execAmount), "원").font(.callout)
                } else {
                    Text(item.canceled ? "취소" : item.status.isEmpty ? "미체결" : item.status)
                        .font(.caption).foregroundStyle(item.canceled ? Color.secondary : Color.orange)
                    Spacer()
                    if item.remainQty > 0, !item.canceled {
                        if cancelingId == item.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("정정") { onModify(item) }
                            Button("취소") { cancelTarget = item }
                        }
                    }
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

    private func cancel(_ item: DailyOrderItem) async {
        guard let client = model.client else { return }
        actionMessage = nil
        cancelingId = item.id
        defer { cancelingId = nil }
        do {
            _ = try await client.cancelOrder(orderNo: item.orderNo, exchange: item.exchange, limitPrice: item.orderPrice)
        } catch {
            actionMessage = error.localizedDescription
        }
        await load()
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

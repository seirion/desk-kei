import DeskKeiCore
import SwiftUI

struct AssetsView: View {
    @EnvironmentObject var model: AppModel
    @State private var loading = false
    @State private var assets: [AssetItem] = []
    @State private var summary: AccountSummary?
    @State private var error: String?
    @State private var showDaily = false

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(Color.up)
                    Button("다시 시도") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading && summary == nil {
                ProgressView("불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .task(id: model.assetsVersion) { await load() }
        .onChange(of: model.tab) { tab in
            if tab == .assets { Task { await load() } }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary { SummaryCard(summary: summary, dailyTotal: assets.reduce(0) { $0 + $1.dailyProfitLoss }) }

                HStack {
                    Text("보유 종목 (\(assets.count))").font(.headline)
                    Spacer()
                    Picker("", selection: $showDaily) {
                        Text("총수익").tag(false)
                        Text("일간수익").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                    if loading { ProgressView().controlSize(.small) }
                    Button("새로고침") { Task { await load() } }
                }

                if assets.isEmpty {
                    Text("보유 종목이 없습니다.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 0) {
                        ForEach(assets) { item in
                            AssetRow(item: item, showDaily: showDaily)
                            Divider()
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func load() async {
        guard let client = model.client else {
            summary = nil
            assets = []
            error = model.account.hasCredentials ? nil : "등록된 계정이 없습니다. 우측 상단 계정 버튼에서 추가해 주세요."
            return
        }
        loading = true
        defer { loading = false }
        do {
            let r = try await client.balance()
            assets = r.assets
            summary = r.summary
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SummaryCard: View {
    let summary: AccountSummary
    let dailyTotal: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("총평가금액").foregroundStyle(.secondary)
                Spacer()
                Text("\(fmt(summary.totalEvaluationAmount))원").font(.system(size: 28, weight: .bold)).monospacedDigit()
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    cell("순자산", "\(fmt(summary.netAssetAmount))원")
                    cell("주식평가", "\(fmt(summary.stockEvaluationAmount))원")
                    cell("예수금(D+2)", "\(fmt(summary.depositAmount))원")
                }
                GridRow {
                    cell("매입금액", "\(fmt(summary.purchaseAmountTotal))원")
                    cell("총평가손익", "\(fmtSigned(summary.profitLossTotal))원", color: pnlColor(summary.profitLossTotal))
                    cell("일간평가손익", "\(fmtSigned(dailyTotal))원", color: pnlColor(dailyTotal))
                }
            }
        }
        .padding(16)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private func cell(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).foregroundStyle(color).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AssetRow: View {
    @EnvironmentObject var model: AppModel
    let item: AssetItem
    let showDaily: Bool

    var body: some View {
        let info = model.stocks[item.code]
        let pnl = showDaily ? item.dailyProfitLoss : item.profitLossAmount
        let rate = showDaily ? item.dailyRate : item.profitLossRate

        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.nameKr).fontWeight(.semibold)
                    if info?.halt == true { Badge(text: "정", color: .gray) }
                    if info?.designated == true { Badge(text: "관", color: .orange) }
                    Text(item.code).font(.caption).foregroundStyle(.secondary)
                }
                Text("\(fmt(item.holdingQty))주 · 평균 \(fmt(Int(item.purchaseAvgPrice.rounded())))원")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(fmt(item.currentPrice))원").monospacedDigit()
                    Text("\(fmtSigned(pnl)) (\(rate > 0 ? "+" : "")\(String(format: "%.2f", rate))%)")
                        .font(.callout)
                        .foregroundStyle(pnlColor(pnl))
                        .monospacedDigit()
                }
                Text("평가 \(fmt(item.evaluationAmount))원").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("주문") { model.goToOrder(code: item.code, name: item.nameKr) }
                .padding(.leading, 8)
        }
        .padding(.vertical, 8)
    }
}

import DeskKeiCore
import SwiftUI

struct WatchlistView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: Int?
    @State private var editing = false

    var body: some View {
        VStack(spacing: 0) {
            groupTabs
            Divider()
            if model.priceLoading {
                Text("현재가 조회 중… (\(model.krxPrices.count)/\(model.currentCodes.count))")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            header
            Divider()
            if model.currentCodes.isEmpty {
                VStack(spacing: 8) {
                    Text("이 그룹에 종목이 없습니다.").foregroundStyle(.secondary)
                    Button("종목 검색해서 추가") { model.showSearch = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.currentCodes, id: \.self) { code in
                            WatchRow(code: code)
                            Divider()
                        }
                    }
                }
            }
        }
        .sheet(item: Binding(get: { renaming.map(GroupID.init) }, set: { renaming = $0?.index })) { g in
            RenameGroupSheet(index: g.index)
        }
        .sheet(isPresented: $editing) { EditWatchlistSheet() }
    }

    private var groupTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(0..<WatchlistFile.groupCount, id: \.self) { i in
                    let selected = model.activeGroup == i
                    Button { model.activeGroup = i } label: {
                        Text(model.groupName(i))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("이름 변경…") { renaming = i } }
                }
            }
            .padding(10)
        }
        // 가로 스크롤 뷰는 세로로도 늘어나므로 내용 높이로 고정한다.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack {
            Color.clear.frame(width: WatchRow.chartWidth, height: 1)
            Text("종목명").frame(maxWidth: .infinity, alignment: .leading)
            Text(MarketClock.isAfterSession() ? "종가 / 애프터" : "현재가")
                .frame(width: 130, alignment: .trailing)
            Text("등락").frame(width: 170, alignment: .trailing)
            Button("편집") { editing = true }
                .buttonStyle(.plain)
                .foregroundStyle(model.currentCodes.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(model.currentCodes.isEmpty)
                .frame(width: 56)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

private struct GroupID: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct WatchRow: View {
    static let chartWidth: CGFloat = 84

    @EnvironmentObject var model: AppModel
    let code: String

    var body: some View {
        let info = model.stocks[code]
        let name = info?.nameKr ?? code
        let krx = model.krxPrices[code]
        let prev = krx?.prevPrice ?? info?.prevPrice ?? 0

        // 시세를 아직 못 받았으면 마스터 기준가(전일 종가)를 보여 준다.
        let krxPrice = krx?.price ?? info?.prevPrice ?? 0
        let krxChange = formatChange(change: krx?.change ?? 0, sign: krx?.sign ?? "3", rate: krx?.rate ?? 0)

        // 애프터마켓이 시작된 뒤에는 현재가(KRX) 가 애프터 가격이므로, 15:30 종가를 첫 줄, 애프터 가격을 둘째 줄에 둔다.
        // 종가는 분봉에서 오므로 분봉을 받기 전에는 한 줄로 보여 준다.
        let close = MarketClock.isAfterSession() && krx != nil ? model.regularClose(code) : nil
        let closeChange = close.map { changeFromPrev(close: $0, prev: prev) }

        HStack {
            Sparkline(bars: model.charts[code] ?? [], prevClose: krx?.prevPrice ?? info?.prevPrice ?? 0)
                .frame(width: Self.chartWidth, height: 30)

            HStack(spacing: 4) {
                Text(name).fontWeight(.medium)
                if info?.halt == true { Badge(text: "정", color: .gray) }
                if info?.designated == true { Badge(text: "관", color: .orange) }
                Text(code).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                if let close, let closeChange {
                    Text(fmt(close))
                        .foregroundStyle(color(for: closeChange.direction))
                    HStack(spacing: 3) {
                        Badge(text: "A", color: .purple)
                        Text(fmt(krxPrice))
                    }
                    .font(.callout)
                    .foregroundStyle(color(for: krxChange.direction))
                } else {
                    Text(krx == nil && model.priceLoading ? "…" : fmt(krxPrice))
                        .foregroundStyle(color(for: krxChange.direction))
                }
            }
            .monospacedDigit()
            .frame(width: 130, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                if let closeChange {
                    Text(closeChange.text)
                        .foregroundStyle(color(for: closeChange.direction))
                    Text(krxChange.text).font(.callout).foregroundStyle(color(for: krxChange.direction))
                } else {
                    Text(krx == nil ? "" : krxChange.text)
                        .foregroundStyle(color(for: krxChange.direction))
                }
            }
            .monospacedDigit()
            .frame(width: 170, alignment: .trailing)

            Button("주문") { model.goToOrder(code: code, name: name) }
                .frame(width: 56)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contextMenu {
            Button("주문") { model.goToOrder(code: code, name: name) }
            Button("관심종목에서 제거", role: .destructive) { model.toggleWatch(code) }
        }
    }
}

/// 전일 종가 대비 종가의 등락. 상·하한가 구분은 하지 않고 방향만 본다.
private func changeFromPrev(close: Int, prev: Int) -> (text: String, direction: PriceDirection) {
    guard prev > 0 else { return ("", .flat) }
    let diff = close - prev
    let rate = Double(abs(diff)) / Double(prev) * 100
    return formatChange(change: abs(diff), sign: diff > 0 ? "2" : diff < 0 ? "5" : "3", rate: rate)
}

private struct EditWatchlistSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var codes: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("관심종목 편집 · \(model.groupName(model.activeGroup))").font(.headline)
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Text("종목을 끌어서 순서를 바꾸고, 오른쪽 x 로 제거합니다.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            ReorderableTable(rows: codes.map { ReorderRow(id: $0, title: model.stocks[$0]?.nameKr ?? $0, subtitle: $0) }, onMove: { order in
                codes = order
                model.setWatchCodes(order)
            }, onRemove: { code in
                codes.removeAll { $0 == code }
                model.toggleWatch(code)
            })
        }
        .frame(width: 420, height: 480)
        .onAppear { codes = model.currentCodes }
    }
}

private struct RenameGroupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let index: Int
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("그룹 이름 변경").font(.headline)
            TextField("그룹 \(index)", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { name = model.watchlist.names[index] }
    }

    private func save() {
        model.renameGroup(index, to: name)
        dismiss()
    }
}

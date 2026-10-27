import DeskKeiCore
import SwiftUI

struct WatchlistView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: Int?

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
            Text("종목명").frame(maxWidth: .infinity, alignment: .leading)
            Text("현재가" + (!MarketClock.isRegularHour() && MarketClock.isNxtHour() ? " / NXT" : ""))
                .frame(width: 130, alignment: .trailing)
            Text("등락").frame(width: 170, alignment: .trailing)
            Color.clear.frame(width: 56, height: 1)
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
    @EnvironmentObject var model: AppModel
    let code: String

    var body: some View {
        let info = model.stocks[code]
        let name = info?.nameKr ?? code
        let krx = model.krxPrices[code]
        let nxt = model.nxtPrices[code].flatMap { $0.price > 0 ? $0 : nil }

        // 시세를 아직 못 받았으면 마스터 기준가(전일 종가)를 보여 준다.
        let krxPrice = krx?.price ?? info?.prevPrice ?? 0
        let krxChange = formatChange(change: krx?.change ?? 0, sign: krx?.sign ?? "3", rate: krx?.rate ?? 0)

        HStack {
            HStack(spacing: 4) {
                Text(name).fontWeight(.medium)
                if info?.halt == true { Badge(text: "정", color: .gray) }
                if info?.designated == true { Badge(text: "관", color: .orange) }
                Text(code).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(krx == nil && model.priceLoading ? "…" : fmt(krxPrice))
                    .foregroundStyle(color(for: krxChange.direction))
                if let nxt {
                    HStack(spacing: 3) {
                        Badge(text: "N", color: .purple)
                        Text(fmt(nxt.price))
                    }
                    .font(.callout)
                    .foregroundStyle(color(for: nxt.direction))
                }
            }
            .monospacedDigit()
            .frame(width: 130, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(krx == nil ? "" : krxChange.text)
                    .foregroundStyle(color(for: krxChange.direction))
                if let nxt {
                    let c = formatChange(change: nxt.change, sign: nxt.sign, rate: nxt.rate)
                    Text(c.text).font(.callout).foregroundStyle(color(for: c.direction))
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

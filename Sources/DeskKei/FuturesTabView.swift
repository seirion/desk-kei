import DeskKeiCore
import SwiftUI

/// 선물/옵션 탭의 최상위 화면: 거래 / 즐겨찾기 하위 탭.
/// 두 화면을 모두 살려 두어 탭을 오가도 입력 중이던 주문 상태가 유지된다.
struct FuturesRootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("선물/옵션 화면", selection: $model.futuresSubTab) {
                ForEach(FuturesSubTab.allCases) { sub in
                    Text(sub == .favorites ? "\(sub.title) (\(model.futuresFavorites.items.count))" : sub.title).tag(sub)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.vertical, 8)
            Divider()
            ZStack {
                sub(.trade) { FuturesView() }
                sub(.favorites) { FuturesFavoritesView(live: model.live) }
            }
        }
    }

    private func sub<V: View>(_ tab: FuturesSubTab, @ViewBuilder content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(model.futuresSubTab == tab ? 1 : 0)
            .allowsHitTesting(model.futuresSubTab == tab)
            .accessibilityHidden(model.futuresSubTab != tab)
    }
}

/// 선물/옵션 즐겨찾기. 행을 누르면 거래 탭에서 그 종목을 연다.
struct FuturesFavoritesView: View {
    @EnvironmentObject var model: AppModel
    /// 즐겨찾기 체결가는 초당 여러 번 바뀌므로 AppModel 과 분리된 LiveMarket 을 직접 구독한다.
    @ObservedObject var live: LiveMarket
    @State private var quotes: [String: StampedQuote] = [:]
    @State private var editing = false
    @State private var notice: String?

    private struct PollKey: Hashable {
        let active: Bool
        let codes: [String]
    }

    private var items: [RecentStock] { model.futuresFavorites.items }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            header
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Text("즐겨찾기한 선물/옵션이 없습니다.").foregroundStyle(.secondary)
                    Text("위 검색창에서 종목을 검색해 추가하세요. 거래 탭의 별로도 담을 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.code) { item in
                            FavoriteRow(item: item, price: displayPrice(item.code))
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: PollKey(active: model.tab == .futures && model.futuresSubTab == .favorites, codes: items.map(\.code))) {
            guard model.tab == .futures, model.futuresSubTab == .favorites, !items.isEmpty else { return }
            // 처음 한 바퀴는 모든 종목을 조회해 기준값을 채운다. 이후에는 실시간으로 받는 종목은 건너뛴다.
            var first = true
            while !Task.isCancelled {
                await refresh(all: first)
                first = false
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { notice = nil }
        }
        .sheet(isPresented: $editing) { EditFavoritesSheet() }
    }

    /// 종목을 검색해 즐겨찾기에 담는다. 결과를 고르면 담고 입력을 비운다(이미 있으면 알리기만 한다).
    private var searchBar: some View {
        HStack(spacing: 10) {
            StockSearchField(
                selectedCode: "", recent: [], onRemoveRecent: { _ in }, floating: true,
                source: { q in model.futures.search(q, limit: 40).map { (code: $0.key, name: $0.name) } }
            ) { key, _ in add(key: key) }
            .frame(width: 320)
            if let notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else if items.count > AppModel.futuresRealtimeLimit {
                Text("실시간은 앞의 \(AppModel.futuresRealtimeLimit)개까지, 나머지는 2초 간격으로 조회합니다")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .zIndex(1)
    }

    private func add(key: String) {
        guard let ins = model.futures.resolve(key: key) else { return }
        notice = model.addFuturesFavorite(code: ins.code, name: ins.title)
            ? "즐겨찾기에 추가: \(ins.title)"
            : "이미 즐겨찾기에 있음: \(ins.title)"
    }

    private var header: some View {
        HStack {
            Text("종목명").frame(maxWidth: .infinity, alignment: .leading)
            Text("현재가").frame(width: 120, alignment: .trailing)
            Text("등락").frame(width: 170, alignment: .trailing)
            Button("편집") { editing = true }
                .buttonStyle(.plain)
                .foregroundStyle(items.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(items.isEmpty)
                .frame(width: 56)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// 화면에 보여 줄 가격: 실시간 체결과 REST 조회 중 더 최근에 받은 값.
    /// 탭을 떠나 있던 사이 거래가 있었으면 남아 있는 체결이 오래됐을 수 있어, 받은 시각으로 비교한다.
    private func displayPrice(_ code: String) -> FavoritePrice? {
        let tick = model.wsConnected ? live.futuresTrades[code] : nil
        let rest = quotes[code]
        if let tick, tick.at >= (rest?.at ?? .distantPast) {
            let t = tick.trade
            return FavoritePrice(price: t.price, change: t.change, sign: t.sign, rate: t.rate)
        }
        return rest.map {
            FavoritePrice(price: $0.quote.price.price, change: $0.quote.price.change, sign: $0.quote.price.sign, rate: $0.quote.price.rate)
        }
    }

    /// 시세를 REST 로 받는다. 5개씩 동시에 요청하고 묶음 사이를 띄워 초당 호출 제한(20건)을 넘지 않게 한다.
    /// 실패한 종목은 이전 값을 두고 다음 바퀴에 다시 시도한다.
    /// all 이 false 면 소켓으로 실시간 체결을 받고 있고 이미 값이 있는 종목은 건너뛴다(소켓이 끊기면 다시 조회한다).
    private func refresh(all: Bool) async {
        guard let client = model.client else { return }
        let streaming = Set(model.futuresRealtimeItems.map(\.code))
        let targets = items.compactMap { item -> FuturesInstrument? in
            if !all, model.wsConnected, streaming.contains(item.code), quotes[item.code] != nil { return nil }
            return model.futures.byCode[item.code]
        }
        for start in stride(from: 0, to: targets.count, by: 5) {
            if Task.isCancelled { return }
            let batch = Array(targets[start..<min(start + 5, targets.count)])
            let results = await withTaskGroup(of: (String, FuturesQuote?).self) { group in
                for ins in batch {
                    group.addTask { (ins.code, (try? await client.futuresQuote(code: ins.code, kind: ins.kind)) ?? nil) }
                }
                var out: [(String, FuturesQuote?)] = []
                for await r in group { out.append(r) }
                return out
            }
            let now = Date()
            for (code, quote) in results {
                if let quote { quotes[code] = StampedQuote(quote: quote, at: now) }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}

private struct StampedQuote {
    let quote: FuturesQuote
    let at: Date
}

private struct FavoritePrice {
    let price: Int
    let change: Int
    let sign: String
    let rate: Double
}

private struct FavoriteRow: View {
    @EnvironmentObject var model: AppModel
    let item: RecentStock
    let price: FavoritePrice?

    var body: some View {
        let ins = model.futures.byCode[item.code]
        // 마스터가 아직 로딩 중일 수 있으므로, 비어 있을 때는 종료된 종목으로 단정하지 않는다.
        let ended = ins == nil && !model.futures.isEmpty
        let change = price.map { formatChange(change: $0.change, sign: $0.sign, rate: $0.rate) }

        Button { model.goToFutures(code: item.code) } label: {
            HStack {
                HStack(spacing: 6) {
                    Text(ins?.title ?? item.name).fontWeight(.medium)
                    Text(item.code).font(.caption).foregroundStyle(.secondary)
                    if ended { Badge(text: "종료", color: .gray) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(price.map { fmt($0.price) } ?? "—")
                    .foregroundStyle(color(for: change?.direction ?? .flat))
                    .frame(width: 120, alignment: .trailing)
                Text(change?.text ?? "")
                    .foregroundStyle(color(for: change?.direction ?? .flat))
                    .frame(width: 170, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    .frame(width: 56)
            }
            .monospacedDigit()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(ended)
        .contextMenu {
            Button("거래") { model.goToFutures(code: item.code) }.disabled(ended)
            Button("즐겨찾기에서 제거", role: .destructive) {
                model.toggleFuturesFavorite(code: item.code, name: item.name)
            }
        }
    }
}

private struct EditFavoritesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var codes: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("선물/옵션 즐겨찾기 편집").font(.headline)
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Text("종목을 끌어서 순서를 바꾸고, 오른쪽 x 로 제거합니다.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            ReorderableTable(rows: codes.map { ReorderRow(id: $0, title: title(of: $0), subtitle: $0) }, onMove: { order in
                codes = order
                model.setFuturesFavoriteOrder(order)
            }, onRemove: { code in
                codes.removeAll { $0 == code }
                model.setFuturesFavoriteOrder(codes)
            })
        }
        .frame(width: 420, height: 480)
        .onAppear { codes = model.futuresFavorites.items.map(\.code) }
    }

    private func title(of code: String) -> String {
        model.futures.byCode[code]?.title ?? model.futuresFavorites.items.first { $0.code == code }?.name ?? code
    }
}

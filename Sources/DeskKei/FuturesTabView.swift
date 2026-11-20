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
                sub(.favorites) { FuturesFavoritesView() }
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
    @State private var quotes: [String: FuturesQuote] = [:]
    @State private var editing = false

    private struct PollKey: Hashable {
        let active: Bool
        let codes: [String]
    }

    private var items: [RecentStock] { model.futuresFavorites.items }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Text("즐겨찾기한 선물/옵션이 없습니다.").foregroundStyle(.secondary)
                    Text("거래 탭에서 종목 이름 옆 별을 눌러 추가하세요.").font(.caption).foregroundStyle(.secondary)
                    Button("거래 탭으로") { model.futuresSubTab = .trade }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.code) { item in
                            FavoriteRow(item: item, quote: quotes[item.code])
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: PollKey(active: model.tab == .futures && model.futuresSubTab == .favorites, codes: items.map(\.code))) {
            guard model.tab == .futures, model.futuresSubTab == .favorites, !items.isEmpty else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .sheet(isPresented: $editing) { EditFavoritesSheet() }
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

    /// 즐겨찾기를 한 바퀴 돌며 시세를 받는다. 초당 호출 제한을 넘지 않도록 사이를 띄우고, 실패한 종목은 이전 값을 둔다.
    private func refresh() async {
        guard let client = model.client else { return }
        for item in items {
            if Task.isCancelled { return }
            guard let ins = model.futures.byCode[item.code] else { continue }
            if let q = (try? await client.futuresQuote(code: ins.code, kind: ins.kind)) ?? nil {
                quotes[item.code] = q
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

private struct FavoriteRow: View {
    @EnvironmentObject var model: AppModel
    let item: RecentStock
    let quote: FuturesQuote?

    var body: some View {
        let ins = model.futures.byCode[item.code]
        // 마스터가 아직 로딩 중일 수 있으므로, 비어 있을 때는 종료된 종목으로 단정하지 않는다.
        let ended = ins == nil && !model.futures.isEmpty
        let change = quote.map { formatChange(change: $0.price.change, sign: $0.price.sign, rate: $0.price.rate) }

        Button { model.goToFutures(code: item.code) } label: {
            HStack {
                HStack(spacing: 6) {
                    Text(ins?.title ?? item.name).fontWeight(.medium)
                    Text(item.code).font(.caption).foregroundStyle(.secondary)
                    if ended { Badge(text: "종료", color: .gray) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(quote.map { fmt($0.price.price) } ?? "—")
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

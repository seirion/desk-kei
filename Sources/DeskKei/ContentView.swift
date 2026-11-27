import DeskKeiCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    ErrorBanner(text: message) { model.errorMessage = nil }
                        .padding([.horizontal, .top], 12)
                }
                // 모든 화면을 살려 두어 탭을 오가도 입력과 스크롤 상태가 유지된다.
                ZStack {
                    page(.assets) { AssetsView() }
                    page(.watchlist, marketOnly: true) { WatchlistView() }
                    page(.order, marketOnly: true) { OrderView() }
                    page(.futures, marketOnly: true) { FuturesRootView() }
                }
            }
            ToastStack()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("화면", selection: $model.tab) {
                    ForEach(AppTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 400)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Text(model.wsConnected ? "● 실시간" : "○ 대기")
                    .font(.caption)
                    .foregroundStyle(model.wsConnected ? Color.green : Color.secondary)
                    .padding(.horizontal, 6)
                Button { model.showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .help("종목 검색 (⌘F)")
                Button { model.openSettings(.accounts) } label: { Image(systemName: "person.crop.circle") }
                    .help("설정 (⌘,)")
            }
        }
        .navigationTitle(model.account.name.isEmpty ? "Desk Kei" : "\(model.account.broker.displayName) · \(model.account.name)")
        .sheet(isPresented: $model.showSearch) { SearchSheet() }
        .sheet(isPresented: $model.showSettings) { SettingsSheet() }
    }

    /// marketOnly: 시세·주문 화면. KIS 가 아닌 증권사 계정이면 안내로 덮는다.
    private func page<V: View>(_ tab: AppTab, marketOnly: Bool = false, @ViewBuilder content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay {
                if marketOnly, model.needsMarketAccount { NeedsMarketAccountNotice(broker: model.account.broker) }
            }
            .opacity(model.tab == tab ? 1 : 0)
            .allowsHitTesting(model.tab == tab)
            .accessibilityHidden(model.tab != tab)
    }
}

/// 시세를 받을 KIS 계정이 없을 때 시세·주문 화면 위에 보여 주는 안내.
/// 키움·KB 계정은 시세를 직접 받지 못하고 KIS 계정의 키로 받는다.
struct NeedsMarketAccountNotice: View {
    @EnvironmentObject var model: AppModel
    let broker: Broker

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.largeTitle).foregroundStyle(.secondary)
            Text("시세·호가를 보려면 한국투자증권 계정이 필요합니다.").font(.headline)
            Text("\(broker.displayName) 계정은 시세를 한국투자증권 계정의 키로 받아서 보여 줍니다.")
                .font(.callout).foregroundStyle(.secondary)
            Button("계정 설정 열기") { model.openSettings(.accounts) }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 체결 알림
struct ToastStack: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.toasts) { t in
                let isBuy = t.side == .buy
                HStack(spacing: 8) {
                    Text(isBuy ? "매수 체결" : "매도 체결").fontWeight(.bold)
                    Text(model.stocks[t.code]?.nameKr ?? t.code)
                    Text("\(fmt(t.execQty))주 × \(fmt(t.execPrice))원").font(.callout)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isBuy ? Color.up : Color.down, in: RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4)
                .onTapGesture { model.dismissToast(t.id) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(16)
        .animation(.default, value: model.toasts)
    }
}

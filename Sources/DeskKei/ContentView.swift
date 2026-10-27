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
                    page(.watchlist) { WatchlistView() }
                    page(.order) { OrderView() }
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
                .frame(width: 300)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Text(model.wsConnected ? "● 실시간" : "○ 대기")
                    .font(.caption)
                    .foregroundStyle(model.wsConnected ? Color.green : Color.secondary)
                Button { model.showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .help("종목 검색 (⌘F)")
                Button { model.showAccounts = true } label: { Image(systemName: "person.crop.circle") }
                    .help("계정 관리 (⌘,)")
            }
        }
        .navigationTitle(model.account.name.isEmpty ? "Desk Kei" : "Desk Kei · \(model.account.name)")
        .sheet(isPresented: $model.showAccounts) { AccountsSheet() }
        .sheet(isPresented: $model.showSearch) { SearchSheet() }
    }

    private func page<V: View>(_ tab: AppTab, @ViewBuilder content: () -> V) -> some View {
        content()
            .opacity(model.tab == tab ? 1 : 0)
            .allowsHitTesting(model.tab == tab)
            .accessibilityHidden(model.tab != tab)
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

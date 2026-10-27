import AppKit
import Combine
import DeskKeiCore
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case assets, watchlist, order
    var id: String { rawValue }
    var title: String {
        switch self {
        case .assets: return "총자산"
        case .watchlist: return "관심종목"
        case .order: return "주식주문"
        }
    }
    var symbol: String {
        switch self {
        case .assets: return "wonsign.circle"
        case .watchlist: return "star"
        case .order: return "list.clipboard"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // 화면 상태
    @Published var tab: AppTab { didSet { tabChanged() } }
    @Published var showAccounts = false
    @Published var showSearch = false
    @Published var errorMessage: String?

    // 계정
    @Published private(set) var accounts: [KisAccount]
    @Published private(set) var activeName: String

    // 종목 / 관심종목
    @Published private(set) var stocks: [String: StockInfo] = [:]
    @Published private(set) var watchlist: WatchlistFile
    @Published var activeGroup: Int { didSet { groupChanged(from: oldValue) } }
    @Published private(set) var krxPrices: [String: KisPrice] = [:]
    @Published private(set) var nxtPrices: [String: KisPrice] = [:]
    @Published private(set) var priceLoading = false

    // 실시간 / 주문
    @Published private(set) var wsConnected = false
    @Published private(set) var toasts: [OrderExecution] = []
    @Published private(set) var orderBook: OrderBook?
    @Published private(set) var liveTrade: RealTimeTrade?
    @Published private(set) var orderCode: String
    /// 외부(주문 버튼)에서 주문 화면의 종목을 바꿀 때마다 증가
    @Published private(set) var orderRequestToken = 0
    @Published private(set) var orderRequestName = ""
    /// 체결 통보 등으로 잔고를 다시 읽어야 할 때 증가
    @Published private(set) var assetsVersion = 0

    private let accountsStore = JSONStore("accounts.json")
    private let watchStore = JSONStore("watchlist.json")
    private let stateStore = JSONStore("state.json")
    private let prefsStore = JSONStore("order.json")

    private var socket: KisWebSocket?
    private var priceTask: Task<Void, Never>?
    private var lastNxtState = MarketClock.isNxtHour()
    private var clockTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let file = accountsStore.load(AccountsFile.self) ?? AccountsFile()
        accounts = file.accounts
        activeName = file.active

        var watch = watchStore.load(WatchlistFile.self) ?? WatchlistFile()
        watch.normalize()
        watchlist = watch

        let state = stateStore.load(AppStateFile.self) ?? AppStateFile()
        tab = AppTab(rawValue: state.lastTab) ?? .watchlist
        activeGroup = min(max(state.activeGroup, 0), WatchlistFile.groupCount - 1)

        orderCode = (prefsStore.load(OrderPrefsFile.self) ?? OrderPrefsFile()).last.code
    }

    // MARK: - 시작

    func start() {
        Task { await loadStocks() }
        if account.hasCredentials { Task { await startSession() } } else { showAccounts = accounts.isEmpty }

        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMarketSession() }
        }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconnectSocket() }
        }
        observers.append(wake)
    }

    private func loadStocks() async {
        do { stocks = try await StockMaster.load() }
        catch { errorMessage = "종목 정보를 불러오지 못했습니다: \(error.localizedDescription)" }
    }

    /// 현재 계정으로 실시간 연결과 관심종목 시세 조회를 시작한다.
    private func startSession() async {
        await startRealtime()
        loadGroupPrices()
    }

    // MARK: - 계정

    var account: KisAccount {
        accounts.first { $0.name == activeName } ?? accounts.first ?? KisAccount()
    }

    var client: KisClient? {
        account.hasCredentials ? KisClient(account: account) : nil
    }

    func saveAccount(_ acc: KisAccount, replacing original: String?) throws {
        let name = acc.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw KisError("계정 이름을 입력해 주세요.") }
        guard acc.hasCredentials else { throw KisError("App Key와 App Secret을 입력해 주세요.") }
        if accounts.contains(where: { $0.name == name && $0.name != original }) {
            throw KisError("이미 같은 이름의 계정이 있습니다.")
        }
        var saved = acc
        saved.name = name
        if let original, let idx = accounts.firstIndex(where: { $0.name == original }) {
            accounts[idx] = saved
            if activeName == original { activeName = name }
        } else {
            accounts.append(saved)
            if activeName.isEmpty { activeName = name }
        }
        persistAccounts()
    }

    func deleteAccount(_ name: String) {
        accounts.removeAll { $0.name == name }
        if activeName == name { activeName = accounts.first?.name ?? "" }
        persistAccounts()
    }

    func activateAccount(_ name: String) {
        activeName = name
        persistAccounts()
        accountChanged()
    }

    private func persistAccounts() {
        var file = AccountsFile()
        file.accounts = accounts
        file.active = activeName
        accountsStore.save(file)
    }

    private func accountChanged() {
        assetsVersion += 1
        krxPrices = [:]
        nxtPrices = [:]
        Task { await startSession() }
    }

    // MARK: - 관심종목

    var currentCodes: [String] {
        var seen = Set<String>()
        return watchlist.groups[activeGroup].filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func groupName(_ i: Int) -> String {
        let n = watchlist.names[i]
        return n.isEmpty ? "그룹 \(i)" : n
    }

    func renameGroup(_ i: Int, to name: String) {
        watchlist.names[i] = name.trimmingCharacters(in: .whitespaces)
        watchStore.save(watchlist)
    }

    func isWatched(_ code: String) -> Bool { watchlist.groups[activeGroup].contains(code) }

    func toggleWatch(_ code: String) {
        if let idx = watchlist.groups[activeGroup].firstIndex(of: code) {
            watchlist.groups[activeGroup].remove(at: idx)
        } else {
            watchlist.groups[activeGroup].append(code)
            fetchSingle(code)
        }
        watchStore.save(watchlist)
        if tab == .watchlist { applySubscription() }
    }

    private func groupChanged(from old: Int) {
        guard old != activeGroup else { return }
        saveState()
        krxPrices = [:]
        nxtPrices = [:]
        loadGroupPrices()
        if tab == .watchlist { applySubscription() }
    }

    func loadGroupPrices() {
        priceTask?.cancel()
        guard let client else { return }
        let codes = currentCodes
        guard !codes.isEmpty else { priceLoading = false; return }
        let group = activeGroup
        priceLoading = true
        priceTask = Task { [weak self] in
            await client.prices(codes: codes, market: "J") { code, p in
                Task { @MainActor in
                    guard let self, self.activeGroup == group else { return }
                    self.krxPrices[code] = p
                }
            }
            if !MarketClock.isRegularHour(), !Task.isCancelled {
                await client.prices(codes: codes, market: "NX") { code, p in
                    Task { @MainActor in
                        guard let self, self.activeGroup == group else { return }
                        self.nxtPrices[code] = p
                    }
                }
            }
            await MainActor.run { [weak self] in
                if self?.activeGroup == group { self?.priceLoading = false }
            }
        }
    }

    private func fetchSingle(_ code: String) {
        guard let client else { return }
        Task {
            if let p = try? await client.price(code: code) { krxPrices[code] = p }
            if !MarketClock.isRegularHour(), let n = try? await client.price(code: code, market: "NX") { nxtPrices[code] = n }
        }
    }

    // MARK: - 주문 화면 연동

    func goToOrder(code: String, name: String) {
        orderCode = code
        orderRequestName = name
        orderRequestToken += 1
        tab = .order
    }

    /// 주문 화면에서 종목이 바뀌었을 때
    func orderStockChanged(code: String) {
        guard code != orderCode else { return }
        orderCode = code
        orderBook = nil
        liveTrade = nil
        if tab == .order { applySubscription() }
    }

    /// REST 로 받아온 초기 호가. 실시간 호가가 아직 없을 때만 반영한다.
    func setInitialOrderBook(_ book: OrderBook) {
        if orderBook == nil, book.code == orderCode { orderBook = book }
    }

    // MARK: - 실시간

    private func startRealtime() async {
        socket?.disconnect()
        socket = nil
        wsConnected = false
        guard let client else { return }
        do {
            let key = try await client.approvalKey()
            let ws = KisWebSocket(approvalKey: key, customerId: account.userId)
            ws.onEvent = { [weak self] in self?.handle($0) }
            ws.onStatusChange = { [weak self] in self?.wsConnected = $0 }
            ws.onConnected = { [weak self] in self?.applySubscription() }
            socket = ws
            ws.connect()
            ws.subscribeExecutions()
        } catch {
            errorMessage = "실시간 연결 준비 실패: \(error.localizedDescription)"
        }
    }

    private func reconnectSocket() {
        guard let socket else { return }
        socket.disconnect()
        socket.connect()
    }

    private func tabChanged() {
        saveState()
        // 탭을 옮길 때마다 재구독: 그 사이 시간대(정규장/NXT)가 바뀌었을 수 있다.
        applySubscription()
    }

    private func checkMarketSession() {
        let nxt = MarketClock.isNxtHour()
        guard nxt != lastNxtState else { return }
        lastNxtState = nxt
        applySubscription()
        loadGroupPrices()
    }

    private func applySubscription() {
        guard let socket else { return }
        socket.unsubscribeAll()
        orderBook = nil
        liveTrade = nil
        switch tab {
        case .watchlist:
            socket.subscribeTrades(currentCodes)
        case .order:
            if !orderCode.isEmpty {
                socket.subscribeTrades([orderCode])
                socket.subscribeOrderBook([orderCode])
                loadInitialOrderBook()
            }
        case .assets:
            break
        }
    }

    /// 재구독하면 호가가 비워지는데 실시간 호가는 변동이 있어야 오므로, 그 사이를 REST 호가로 채운다.
    private func loadInitialOrderBook() {
        guard let client else { return }
        let code = orderCode
        Task {
            if let book = try? await client.askingPrice(code: code) { setInitialOrderBook(book) }
        }
    }

    private func handle(_ event: RealtimeEvent) {
        switch event {
        case .trade(let t):
            if tab == .order {
                if t.code == orderCode { liveTrade = t }
            } else {
                let prev = t.price - (t.sign == "4" || t.sign == "5" ? -t.change : t.change)
                let price = KisPrice(price: t.price, prevPrice: prev, change: t.change, sign: t.sign, rate: t.rate,
                                     open: t.open, high: t.high, low: t.low, volume: t.volume)
                if t.isNxt { nxtPrices[t.code] = price } else { krxPrices[t.code] = price }
            }
        case .orderBook(let book):
            if book.code == orderCode { orderBook = book }
        case .execution(let exec):
            toasts.append(exec)
            assetsVersion += 1
            let id = exec.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.toasts.removeAll { $0.id == id }
            }
        }
    }

    func dismissToast(_ id: UUID) { toasts.removeAll { $0.id == id } }

    // MARK: - 저장

    private func saveState() {
        var s = AppStateFile()
        s.lastTab = tab.rawValue
        s.activeGroup = activeGroup
        stateStore.save(s)
    }
}

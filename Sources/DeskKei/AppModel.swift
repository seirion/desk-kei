import AppKit
import Combine
import DeskKeiCore
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case assets, watchlist, order, futures
    var id: String { rawValue }
    var title: String {
        switch self {
        case .assets: return "총자산"
        case .watchlist: return "관심종목"
        case .order: return "주식주문"
        case .futures: return "선물/옵션"
        }
    }
    var symbol: String {
        switch self {
        case .assets: return "wonsign.circle"
        case .watchlist: return "star"
        case .order: return "list.clipboard"
        case .futures: return "chart.line.uptrend.xyaxis"
        }
    }
}

/// 선물/옵션 화면 안의 탭
enum FuturesSubTab: String, CaseIterable, Identifiable {
    case trade, favorites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trade: return "거래"
        case .favorites: return "즐겨찾기"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "시스템"
        case .light: return "라이트"
        case .dark: return "다크"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class LiveMarket: ObservableObject {
    @Published var orderBook: OrderBook?
    @Published var liveTrade: RealTimeTrade?
    /// 선물/옵션 화면의 실시간 호가 (최대 10호가)
    @Published var futuresBook: OrderBook?
    /// 선물/옵션 즐겨찾기의 실시간 체결가 (단축코드별 마지막 체결)
    @Published var futuresTrades: [String: FuturesTick] = [:]
}

/// 실시간 체결과 받은 시각. 구독하지 않던 사이 거래가 있었을 수 있어, 오래된 체결이 더 최근에 조회한 시세를 덮지 않게 한다.
struct FuturesTick {
    let trade: RealTimeTrade
    let at: Date
}

@MainActor
final class AppModel: ObservableObject {
    // 화면 상태
    @Published var tab: AppTab { didSet { tabChanged() } }
    @Published var showSearch = false
    @Published var showSettings = false
    @Published var settingsTab: SettingsTab = .accounts
    @Published var errorMessage: String?

    // 계정
    @Published private(set) var accounts: [BrokerAccount]
    @Published private(set) var activeName: String
    /// 시세에 쓸 KIS 계정으로 고른 이름 (비어 있으면 자동)
    @Published private(set) var marketAccountName: String

    // 종목 / 관심종목
    @Published private(set) var stocks: [String: StockInfo] = [:]
    /// NXT 거래 종목 코드. nil 이면 아직 못 받은 것이므로 모든 종목을 거래 가능으로 본다.
    @Published private(set) var nxtCodes: Set<String>?
    @Published private(set) var masterUpdatedAt: Date?
    @Published private(set) var masterRefreshing = false
    @Published private(set) var masterError: String?
    /// 주식선물옵션 종목 (기초자산·월물·행사가 선택과 검색용)
    @Published private(set) var futures = FuturesCatalog(instruments: [])
    @Published private(set) var futuresUpdatedAt: Date?
    /// 현재 계정에 선물옵션 계좌가 있는지. notFound 면 선물/옵션 주문을 막는다.
    @Published private(set) var futuresAccount: FuturesAccountStatus = .unknown
    private var futuresAccountChecking = false
    @Published private(set) var futuresFavorites: FuturesFavoritesFile
    @Published var futuresSubTab: FuturesSubTab = .trade
    /// 즐겨찾기에서 거래 탭으로 넘길 종목. 바뀔 때마다 token 이 증가한다.
    @Published private(set) var futuresRequestCode: String?
    @Published private(set) var futuresRequestToken = 0
    @Published private(set) var watchlist: WatchlistFile
    @Published var activeGroup: Int { didSet { groupChanged(from: oldValue) } }
    @Published var confirmOrders: Bool { didSet { saveState() } }
    @Published var appearance: AppearanceMode {
        didSet {
            NSApplication.shared.appearance = appearance.nsAppearance
            saveState()
        }
    }
    /// 관심종목에 보여 줄 현재가. 정규장·애프터는 KRX, NXT 프리마켓(08:00~08:50)에는 NXT 가격이다.
    @Published private(set) var krxPrices: [String: KisPrice] = [:]
    @Published private(set) var priceLoading = false
    @Published private(set) var charts: [String: [MinuteBar]] = [:]

    // 실시간 / 주문
    @Published private(set) var wsConnected = false
    @Published private(set) var toasts: [OrderExecution] = []
    /// 호가·체결은 초당 여러 번 바뀌므로 AppModel 과 분리해, 필요한 뷰만 구독한다.
    let live = LiveMarket()
    @Published private(set) var orderCode: String
    /// 현재 구독에서 실시간 호가를 한 번이라도 받았는지
    private var orderBookIsLive = false
    /// 외부(주문 버튼)에서 주문 화면의 종목을 바꿀 때마다 증가
    @Published private(set) var orderRequestToken = 0
    @Published private(set) var orderRequestName = ""
    /// 체결 통보 등으로 잔고를 다시 읽어야 할 때 증가
    @Published private(set) var assetsVersion = 0
    /// 선물/옵션 화면에서 보고 있는 종목 (실시간 호가 구독 대상)
    private var futuresCode = ""
    private var futuresKind: FuturesKind = .future

    private let accountsStore = JSONStore("accounts.json")
    private let watchStore = JSONStore("watchlist.json")
    private let stateStore = JSONStore("state.json")
    private let prefsStore = JSONStore("order.json")
    private let futuresFavoritesStore = JSONStore("futures_favorites.json")

    private var socket: KisWebSocket?
    private var priceTask: Task<Void, Never>?
    private var chartTask: Task<Void, Never>?
    private var chartFetchedAt: [String: Date] = [:]
    private var chartDay = ""
    private var lastNxtState = MarketClock.isNxtHour()
    private var lastAfterSession = MarketClock.isAfterSession()
    private var lastPremarket = MarketClock.isNxtPremarket()
    /// 관심종목 현재가를 REST 로 마지막으로 받은 시각. 앱이 다시 앞으로 나올 때 오래됐는지 보는 데 쓴다.
    private var priceLoadedAt: Date?
    private static let priceStaleSeconds: TimeInterval = 60
    private var clockTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let file = accountsStore.load(AccountsFile.self) ?? AccountsFile()
        accounts = file.accounts
        activeName = file.active
        marketAccountName = file.marketAccount

        var watch = watchStore.load(WatchlistFile.self) ?? WatchlistFile()
        watch.normalize()
        watchlist = watch

        let state = stateStore.load(AppStateFile.self) ?? AppStateFile()
        tab = AppTab(rawValue: state.lastTab) ?? .watchlist
        activeGroup = min(max(state.activeGroup, 0), WatchlistFile.groupCount - 1)
        appearance = AppearanceMode(rawValue: state.appearance) ?? .system
        confirmOrders = state.confirmOrders

        orderCode = (prefsStore.load(OrderPrefsFile.self) ?? OrderPrefsFile()).last.code
        futuresFavorites = futuresFavoritesStore.load(FuturesFavoritesFile.self) ?? FuturesFavoritesFile()
    }

    func openSettings(_ tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        showSettings = true
    }

    // MARK: - 시작

    func start() {
        NSApplication.shared.appearance = appearance.nsAppearance
        Task { await loadStocks() }
        Task { await loadNxtCodes() }
        Task { await loadFutures() }
        if account.hasCredentials { Task { await startSession() } } else if accounts.isEmpty { openSettings(.accounts) }

        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMarketSession() }
        }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.reconnectSocket()
                // 깨어난 직후에는 네트워크가 아직 안 붙었을 수 있어 잠시 뒤에 시간대와 시세를 확인한다.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.resumeCheck()
            }
        }
        observers.append(wake)
        // 가려져 있던 앱이 다시 앞으로 나올 때: 가려진 동안 타이머가 늦춰졌을 수 있다.
        let active = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeCheck() }
        }
        observers.append(active)
    }

    private func loadStocks() async {
        do { stocks = try await StockMaster.load() }
        catch { errorMessage = "종목 정보를 불러오지 못했습니다: \(error.localizedDescription)" }
        masterUpdatedAt = StockMaster.cachedAt()
    }

    /// 목록을 못 받아도 표시만 빠질 뿐이라 오류를 띄우지 않는다.
    private func loadNxtCodes() async {
        guard let codes = try? await NxtMaster.load() else { return }
        nxtCodes = codes
        // 프리마켓에는 거래 불가 종목을 NXT 로 조회하지 않으므로 목록이 들어오면 다시 받는다.
        if MarketClock.isNxtPremarket() { loadGroupPrices() }
    }

    /// 프리장·애프터에 거래되는 종목인지. NXT 목록을 못 받았으면 true.
    func tradesOffHours(_ code: String) -> Bool {
        nxtCodes?.contains(code) ?? true
    }

    /// 지금 시간대에 현재가를 어느 시장으로 조회할지. 프리마켓에는 NXT 거래 종목만 NXT, 나머지는 KRX(전일 기준).
    private func priceMarket(for code: String) -> String {
        MarketClock.isNxtPremarket() && tradesOffHours(code) ? "NX" : "J"
    }

    private func loadFutures() async {
        do { futures = FuturesCatalog(instruments: try await FuturesMaster.load()) }
        catch { errorMessage = "선물옵션 종목 정보를 불러오지 못했습니다: \(error.localizedDescription)" }
        futuresUpdatedAt = FuturesMaster.cachedAt()
        syncFuturesTrades()
    }

    /// 캐시와 상관없이 종목 마스터(주식·선물옵션)를 지금 새로 받는다.
    func refreshMaster() async {
        guard !masterRefreshing else { return }
        masterRefreshing = true
        masterError = nil
        defer { masterRefreshing = false }
        var failures: [String] = []
        do {
            stocks = try await StockMaster.load(force: true)
            masterUpdatedAt = StockMaster.cachedAt()
        } catch {
            failures.append("종목: \(error.localizedDescription)")
        }
        do {
            futures = FuturesCatalog(instruments: try await FuturesMaster.load(force: true))
            futuresUpdatedAt = FuturesMaster.cachedAt()
            syncFuturesTrades()
        } catch {
            failures.append("선물옵션: \(error.localizedDescription)")
        }
        do { nxtCodes = try await NxtMaster.load(force: true) }
        catch { failures.append("NXT 종목: \(error.localizedDescription)") }
        if !failures.isEmpty { masterError = "갱신하지 못했습니다: " + failures.joined(separator: " / ") }
    }

    /// 현재 계정으로 실시간 연결과 관심종목 시세 조회를 시작한다.
    private func startSession() async {
        futuresAccount = .unknown
        Task { await refreshFuturesAccount() }
        await startRealtime()
        loadGroupPrices()
    }

    /// 선물옵션 계좌 유무를 서버에 확인한다. 계정이 바뀌었으면 결과를 버린다.
    func refreshFuturesAccount() async {
        guard !futuresAccountChecking, let client else { return }
        futuresAccountChecking = true
        defer { futuresAccountChecking = false }
        let name = activeName
        let code = futures.instruments.first { $0.kind == .future }?.code ?? "A11612"
        let status = await client.futuresAccountStatus(code: code)
        guard name == activeName else { return }
        futuresAccount = status
    }

    // MARK: - 계정

    var account: BrokerAccount {
        accounts.first { $0.name == activeName } ?? accounts.first ?? BrokerAccount()
    }

    /// 주문·계좌에 쓰는 KIS 클라이언트. 사용 중인 계정이 KIS 가 아니면 nil 이라 KIS 주문 기능은 동작하지 않는다.
    var client: KisClient? {
        account.broker == .kis && account.hasCredentials ? KisClient(account: account) : nil
    }

    /// 인증 정보가 있는 KIS 계정들
    var kisAccounts: [BrokerAccount] { accounts.filter { $0.broker == .kis && $0.hasCredentials } }

    /// 시세·호가·차트·실시간에 쓰는 KIS 계정. 사용 중인 계정이 KIS 면 그 계정이고,
    /// 아니면 설정에서 고른 KIS 계정, 없으면 첫 KIS 계정이다. KIS 계정이 없으면 nil.
    var marketAccount: BrokerAccount? {
        if account.broker == .kis, account.hasCredentials { return account }
        return kisAccounts.first { $0.name == marketAccountName } ?? kisAccounts.first
    }

    /// 시세 조회용 KIS 클라이언트
    var marketClient: KisClient? { marketAccount.map { KisClient(account: $0) } }

    /// 인증 정보는 있는데 시세를 받을 KIS 계정이 없는 상태 (KIS 가 아닌 계정만 등록한 경우)
    var needsMarketAccount: Bool { account.hasCredentials && marketAccount == nil }

    /// 사용 중인 계정이 KIS 가 아니라서 시세를 다른 KIS 계정으로 받고 있는지
    var usesSeparateMarketAccount: Bool { account.hasCredentials && account.broker != .kis && marketAccount != nil }

    /// 시세 계정을 고른다. 시세·실시간을 새 계정으로 다시 연결한다.
    func setMarketAccount(_ name: String) {
        guard name != marketAccountName else { return }
        marketAccountName = name
        persistAccounts()
        krxPrices = [:]
        Task { await startSession() }
    }

    /// 증권사와 관계없이 자산 조회에 쓰는 클라이언트
    var brokerClient: BrokerClient? { BrokerClients.make(account) }

    /// 주식 주문·정정·취소·주문내역에 쓰는 클라이언트 (KIS·KB). 지원하지 않는 증권사면 nil.
    var tradingClient: TradingBroker? { BrokerClients.makeTrading(account) }

    /// 입력한 계정으로 인증(토큰 발급)이 되는지 확인한다. 저장된 토큰이 아니라 입력값으로 새로 확인한다.
    func verifyAccount(_ acc: BrokerAccount) async throws {
        if let message = acc.missingFieldMessage { throw KisError(message) }
        // 토큰 캐시를 거치지 않도록 일회용 저장소를 쓴다.
        let scratch = JSONStore("tokens_verify_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: JSONStore.directory.appendingPathComponent(scratch.filename)) }
        guard let client = BrokerClients.make(acc, tokenStore: scratch) else { throw KisError.notConfigured }
        try await client.verify()
    }

    func saveAccount(_ acc: BrokerAccount, replacing original: String?) throws {
        let name = acc.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw KisError("계정 이름을 입력해 주세요.") }
        if let message = acc.missingFieldMessage { throw KisError(message) }
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
        // 계좌번호를 고쳤을 수 있으므로 쓰고 있는 계정이면 다시 확인한다.
        if saved.name == activeName { futuresAccount = .unknown; Task { await refreshFuturesAccount() } }
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
        file.marketAccount = marketAccountName
        accountsStore.save(file)
    }

    /// 총자산·보유 종목을 다시 불러온다.
    func refreshAssets() { assetsVersion += 1 }

    private func accountChanged() {
        assetsVersion += 1
        krxPrices = [:]
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

    /// 현재 그룹의 종목을 주어진 순서로 바꾼다.
    func setWatchCodes(_ codes: [String]) {
        watchlist.groups[activeGroup] = codes
        watchStore.save(watchlist)
    }

    private func groupChanged(from old: Int) {
        guard old != activeGroup else { return }
        saveState()
        krxPrices = [:]
        loadGroupPrices()
        if tab == .watchlist { applySubscription() }
    }

    func loadGroupPrices() {
        priceTask?.cancel()
        guard let client = marketClient else { return }
        let codes = currentCodes
        guard !codes.isEmpty else { priceLoading = false; return }
        let group = activeGroup
        priceLoading = true
        let nxtList = codes.filter { priceMarket(for: $0) == "NX" }
        let krxList = codes.filter { priceMarket(for: $0) == "J" }
        priceTask = Task { [weak self] in
            for (list, market) in [(nxtList, "NX"), (krxList, "J")] where !list.isEmpty {
                await client.prices(codes: list, market: market) { code, p in
                    Task { @MainActor in
                        guard let self, self.activeGroup == group else { return }
                        self.krxPrices[code] = p
                        self.priceLoadedAt = Date()
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.activeGroup == group else { return }
                self.priceLoading = false
                self.loadCharts()
            }
        }
    }

    /// 현재 그룹 종목의 1일 분봉 차트를 받는다. 최근 5분 안에 받은 종목은 건너뛴다.
    private func loadCharts() {
        chartTask?.cancel()
        guard let client = marketClient else { return }
        let today = MarketClock.todayString()
        if chartDay != today {
            chartDay = today
            charts = [:]
            chartFetchedAt = [:]
        }
        let codes = currentCodes.filter { code in
            chartFetchedAt[code].map { Date().timeIntervalSince($0) > 300 } ?? true
        }
        guard !codes.isEmpty else { return }
        chartTask = Task { [weak self] in
            for code in codes {
                if Task.isCancelled { return }
                guard let bars = try? await client.minuteBars(code: code) else { continue }
                await MainActor.run { self?.setChart(code, bars) }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    /// 15:30 정규장 종가. 오늘 1분봉에서 15:30 이전 마지막 봉의 가격이다. 분봉을 아직 못 받았으면 nil.
    func regularClose(_ code: String) -> Int? {
        guard let bar = charts[code]?.last(where: { $0.minute <= 15 * 60 + 30 && $0.minute >= 9 * 60 }), bar.price > 0 else { return nil }
        return bar.price
    }

    private func setChart(_ code: String, _ bars: [MinuteBar]) {
        // 조회하는 사이 실시간으로 이어 붙인 점이 더 최신이면 남긴다.
        let newest = bars.last?.minute ?? -1
        charts[code] = bars + (charts[code] ?? []).filter { $0.minute > newest }
        chartFetchedAt[code] = Date()
    }

    private func appendLive(code: String, price: Int) {
        guard var bars = charts[code] else { return }
        MinuteChart.upsert(&bars, minute: MarketClock.minutes(Date()), price: price)
        charts[code] = bars
    }

    private func fetchSingle(_ code: String) {
        guard let client = marketClient else { return }
        Task {
            if let p = try? await client.price(code: code, market: priceMarket(for: code)) { krxPrices[code] = p }
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
        live.orderBook = nil
        orderBookIsLive = false
        live.liveTrade = nil
        if tab == .order { applySubscription() }
    }

    /// REST 로 받아온 초기 호가. 재구독 이후 실시간 호가가 아직 오지 않았을 때만 반영한다.
    func setInitialOrderBook(_ book: OrderBook) {
        if !orderBookIsLive, book.code == orderCode { live.orderBook = book }
    }

    /// 선물/옵션 즐겨찾기에서 종목을 눌렀을 때: 거래 탭으로 옮겨 그 종목을 연다.
    func goToFutures(code: String) {
        futuresRequestCode = code
        futuresRequestToken += 1
        futuresSubTab = .trade
        tab = .futures
    }

    func isFuturesFavorite(_ code: String) -> Bool { futuresFavorites.contains(code) }

    func toggleFuturesFavorite(code: String, name: String) {
        futuresFavorites.toggle(code: code, name: name)
        futuresFavoritesStore.save(futuresFavorites)
        syncFuturesTrades()
    }

    /// 검색에서 고른 종목을 즐겨찾기에 담는다. 새로 담았으면 true, 이미 있으면 false.
    @discardableResult
    func addFuturesFavorite(code: String, name: String) -> Bool {
        let added = futuresFavorites.add(code: code, name: name)
        if added {
            futuresFavoritesStore.save(futuresFavorites)
            syncFuturesTrades()
        }
        return added
    }

    func setFuturesFavoriteOrder(_ codes: [String]) {
        futuresFavorites.reorder(codes)
        futuresFavoritesStore.save(futuresFavorites)
        syncFuturesTrades()
    }

    /// KIS 는 WebSocket 한 세션에 구독을 41건까지 허용한다. 체결통보·호가 구독을 빼고 남는 만큼만 즐겨찾기에 쓴다.
    static let futuresRealtimeLimit = 30

    /// 즐겨찾기 중 실시간 체결가를 받는 종목: 마스터에 있는 종목을 앞에서부터 limit 개.
    var futuresRealtimeItems: [(code: String, kind: FuturesKind)] {
        futuresFavorites.items.compactMap { futures.byCode[$0.code] }
            .prefix(Self.futuresRealtimeLimit).map { (code: $0.code, kind: $0.kind) }
    }

    /// 선물/옵션 탭을 보는 동안 즐겨찾기 체결가 구독을 목록에 맞춘다.
    private func syncFuturesTrades() {
        guard tab == .futures, let socket else { return }
        socket.setFuturesTrades(futuresRealtimeItems)
    }

    /// 선물/옵션 화면에서 종목이 바뀌었을 때
    func futuresInstrumentChanged(_ ins: FuturesInstrument) {
        guard ins.code != futuresCode else { return }
        futuresCode = ins.code
        futuresKind = ins.kind
        live.futuresBook = nil
        // 호가 구독만 바꾼다. 전체를 해지했다 다시 걸면 즐겨찾기 체결 구독까지 매번 끊겼다 이어진다.
        if tab == .futures { socket?.setFuturesBook(code: ins.code, kind: ins.kind) }
    }

    // MARK: - 실시간

    private func startRealtime() async {
        socket?.disconnect()
        socket = nil
        wsConnected = false
        guard let client = marketClient else { return }
        do {
            let key = try await client.approvalKey()
            // 체결 통보(주문 계정의 HTS ID)는 시세 계정이 사용 중인 계정과 같을 때만 받는다.
            let ws = KisWebSocket(approvalKey: key, customerId: account.broker == .kis ? account.userId : "")
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
        // 선물옵션 계좌를 아직 확인하지 못했거나 없다고 나왔으면, 탭에 들어올 때 다시 확인한다(그 사이 개설했을 수 있다).
        if tab == .futures, futuresAccount != .available { Task { await refreshFuturesAccount() } }
        if tab == .watchlist {
            // 다른 탭에 있는 동안은 관심종목 실시간 구독이 꺼져 있었으므로 오래됐으면 다시 받는다.
            if isPriceStale { loadGroupPrices() } else { loadCharts() }
        }
        // 탭을 옮길 때마다 재구독: 그 사이 시간대(정규장/NXT)가 바뀌었을 수 있다.
        applySubscription()
    }

    private var isPriceStale: Bool {
        guard let at = priceLoadedAt else { return true }
        return Date().timeIntervalSince(at) > Self.priceStaleSeconds
    }

    /// 앱이 다시 활성화되거나 깨어났을 때: 시간대가 바뀌었으면 구독·시세를 다시 잡고, 아니어도 관심종목 시세가 오래됐으면 다시 받는다.
    private func resumeCheck() {
        if checkMarketSession() { return }
        if tab == .watchlist, isPriceStale { loadGroupPrices() }
    }

    /// 시간대(정규장/NXT/애프터)가 바뀌었으면 구독과 현재가를 다시 잡고 true.
    @discardableResult
    private func checkMarketSession() -> Bool {
        let nxt = MarketClock.isNxtHour()
        let after = MarketClock.isAfterSession()
        let pre = MarketClock.isNxtPremarket()
        guard nxt != lastNxtState || after != lastAfterSession || pre != lastPremarket else { return false }
        lastNxtState = nxt
        lastAfterSession = after
        lastPremarket = pre
        applySubscription()
        loadGroupPrices()
        return true
    }

    private func applySubscription() {
        guard let socket else { return }
        socket.unsubscribeAll()
        // 같은 종목의 호가는 비우지 않는다: 비우면 호가창이 대기 문구로 깜빡인다. 새 값이 오면 덮어쓴다.
        orderBookIsLive = false
        if live.orderBook?.code != orderCode { live.orderBook = nil }
        live.liveTrade = nil
        live.futuresBook = nil
        switch tab {
        case .watchlist:
            // 관심종목은 NXT 프리마켓(08:00~08:50)에만 NXT 체결을 받고, 그 밖에는 KRX 체결(애프터마켓 포함)을 받는다.
            // 프리마켓에는 NXT 거래 종목만 구독한다.
            let premarket = MarketClock.isNxtPremarket()
            socket.subscribeTrades(premarket ? currentCodes.filter(tradesOffHours) : currentCodes, krxOnly: !premarket)
        case .order:
            if !orderCode.isEmpty {
                socket.subscribeTrades([orderCode])
                socket.subscribeOrderBook([orderCode])
                loadInitialOrderBook()
            }
        case .futures:
            // 거래 탭의 시세는 REST 로 주기적으로 조회하고, 호가만 실시간(최대 10호가)으로 받는다.
            socket.setFuturesBook(code: futuresCode.isEmpty ? nil : futuresCode, kind: futuresKind)
            // 즐겨찾기 종목의 체결가도 실시간으로 받는다.
            socket.setFuturesTrades(futuresRealtimeItems)
        case .assets:
            break
        }
    }

    /// 재구독하면 호가가 비워지는데 실시간 호가는 변동이 있어야 오므로, 그 사이를 REST 호가로 채운다.
    private func loadInitialOrderBook() {
        guard let client = marketClient else { return }
        let code = orderCode
        Task {
            if let book = try? await client.askingPrice(code: code) { setInitialOrderBook(book) }
        }
    }

    private func handle(_ event: RealtimeEvent) {
        switch event {
        case .trade(let t):
            if tab == .order {
                if t.code == orderCode { live.liveTrade = t }
            } else {
                let prev = t.price - (t.sign == "4" || t.sign == "5" ? -t.change : t.change)
                let price = KisPrice(price: t.price, prevPrice: prev, change: t.change, sign: t.sign, rate: t.rate,
                                     open: t.open, high: t.high, low: t.low, volume: t.volume)
                krxPrices[t.code] = price
                appendLive(code: t.code, price: t.price)
            }
        case .orderBook(let book):
            if book.code == futuresCode, tab == .futures { live.futuresBook = book }
            else if book.code == orderCode { live.orderBook = book; orderBookIsLive = true }
        case .futuresTrade(let t):
            live.futuresTrades[t.code] = FuturesTick(trade: t, at: Date())
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
        s.appearance = appearance.rawValue
        s.confirmOrders = confirmOrders
        stateStore.save(s)
    }
}

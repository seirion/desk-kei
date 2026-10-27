import DeskKeiCore
import SwiftUI

private enum OrderSubTab: String, CaseIterable, Identifiable {
    case order = "주문", history = "주문내역"
    var id: String { rawValue }
}

private enum Field { case price, qty, search }

struct OrderView: View {
    @EnvironmentObject var model: AppModel

    @State private var subTab: OrderSubTab = .order
    @State private var side: OrderSide = .buy
    @State private var orderType: OrderType = .limit

    @State private var searchQuery = ""
    @State private var prefs = JSONStore("order.json").load(OrderPrefsFile.self) ?? OrderPrefsFile()
    @FocusState private var focus: Field?

    @State private var code = ""
    @State private var name = ""
    @State private var currentPrice: KisPrice?
    @State private var priceLoading = false
    @State private var inputPrice = ""
    @State private var inputQty = ""
    @State private var buyable: BuyableInfo?
    @State private var holdings: [AssetItem] = []

    @State private var submitting = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?
    @State private var confirmMessage: String?
    @State private var modifyTarget: DailyOrderItem?
    @State private var started = false

    private let prefsStore = JSONStore("order.json")

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $subTab) {
                ForEach(OrderSubTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(10)
            Divider()

            ZStack {
                orderLayout
                    .opacity(subTab == .order ? 1 : 0)
                    .allowsHitTesting(subTab == .order)
                if subTab == .history {
                    OrderHistoryView { item in
                        modifyTarget = item
                        subTab = .order
                    }
                }
            }
        }
        .onAppear(perform: startIfNeeded)
        .onChange(of: model.orderRequestToken) { _ in
            Task { await select(code: model.orderCode, name: model.orderRequestName) }
        }
        .onChange(of: model.tab) { tab in
            if tab == .order { Task { await loadHoldings() } }
        }
        .onChange(of: model.assetsVersion) { _ in Task { await loadHoldings() } }
        .onChange(of: modifyTarget) { target in
            guard let t = target else { return }
            Task { await select(code: t.code, name: t.nameKr) }
            side = t.side
            inputPrice = String(t.orderPrice)
            inputQty = String(t.remainQty)
        }
        .alert("주문 확인", isPresented: Binding(get: { confirmMessage != nil }, set: { if !$0 { confirmMessage = nil } })) {
            Button(modifyTarget == nil ? "주문" : "정정") { Task { await submit() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text(confirmMessage ?? "")
        }
    }

    // MARK: 레이아웃

    private var orderLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            OrderBookPanel(currentPrice: currentPrice, hasCode: !code.isEmpty) { inputPrice = String($0) }
                .frame(width: 240)
            Divider()
            ScrollView {
                form.padding(16)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let modifyTarget {
                HStack {
                    Text("✏️ 주문 정정 모드 — \(modifyTarget.side == .buy ? "매수" : "매도") · 잔여 \(fmt(modifyTarget.remainQty))주")
                    Spacer()
                    Button { self.modifyTarget = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(spacing: 0) {
                    sideButton(.buy, "매수", .up)
                    sideButton(.sell, "매도", .down)
                }
            }

            stockSearch
            selectedStockInfo
            if side == .sell, !holdings.isEmpty, modifyTarget == nil { holdingsRow }
            inputs
            quickRow
            if orderType == .limit, totalAmount > 0 {
                Text("총 주문금액: **\(fmt(totalAmount))**원").frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let resultMessage { banner(resultMessage, color: .green) { self.resultMessage = nil } }
            if let errorMessage { banner(errorMessage, color: .up) { self.errorMessage = nil } }
            submitButton
        }
    }

    private func sideButton(_ s: OrderSide, _ label: String, _ tint: Color) -> some View {
        Button { side = s; inputQty = ""; buyable = nil; refreshBuyable() } label: {
            Text(label).fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 8)
                .foregroundStyle(side == s ? Color.white : tint)
                .background(side == s ? tint : tint.opacity(0.1))
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 종목 검색 / 선택 정보

    private var stockSearch: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("종목명 또는 코드 검색", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .search)
                    .onSubmit {
                        if let first = searchResults.first { Task { await select(code: first.code, name: first.name) } }
                    }
                    .onExitCommand { searchQuery = ""; focus = nil }
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            let suggestions: [(code: String, name: String, recent: Bool)] =
                !searchResults.isEmpty
                ? searchResults.map { ($0.code, $0.name, false) }
                : (focus == .search && searchQuery.isEmpty ? prefs.recent.map { ($0.code, $0.name, true) } : [])
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if suggestions.first?.recent == true {
                        Text("최근 종목").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 6)
                    }
                    ForEach(suggestions, id: \.code) { s in
                        Button { Task { await select(code: s.code, name: s.name) } } label: {
                            HStack {
                                Text(s.name)
                                Text(s.code).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .padding(.top, 4)
            }
        }
    }

    private var searchResults: [StockSearch.Result] {
        StockSearch.search(model.stocks, query: searchQuery, limit: 8)
    }

    @ViewBuilder
    private var selectedStockInfo: some View {
        if !code.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.title3).fontWeight(.bold)
                    Text(code).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if priceLoading {
                        Text("조회 중…").font(.caption).foregroundStyle(.secondary)
                    } else if let p = currentPrice {
                        let c = formatChange(change: p.change, sign: p.sign, rate: nil)
                        Text("\(fmt(p.price))원 \(c.text) (\(String(format: "%.2f", p.rate))%)")
                            .foregroundStyle(color(for: c.direction)).fontWeight(.semibold).monospacedDigit()
                    }
                }
                if currentPrice != nil || liveTrade != nil { ohlcv }
            }
        }
    }

    private var liveTrade: RealTimeTrade? {
        model.liveTrade?.code == code ? model.liveTrade : nil
    }

    private var ohlcv: some View {
        let open = liveTrade?.open ?? currentPrice?.open ?? 0
        let high = liveTrade?.high ?? currentPrice?.high ?? 0
        let low = liveTrade?.low ?? currentPrice?.low ?? 0
        let close = liveTrade?.price ?? currentPrice?.price ?? 0
        let vol = liveTrade?.volume ?? currentPrice?.volume ?? 0
        return HStack(spacing: 14) {
            ohlcvItem("시", fmt(open), .primary)
            ohlcvItem("고", fmt(high), .up)
            ohlcvItem("저", fmt(low), .down)
            ohlcvItem("종", fmt(close), .primary)
            ohlcvItem("량", formatVolume(vol), .primary)
        }
        .font(.callout).monospacedDigit()
    }

    private func ohlcvItem(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(tint == .primary ? Color.secondary : tint).font(.caption)
            Text(value).foregroundStyle(tint)
        }
    }

    private var holdingsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("보유 종목").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(holdings) { item in
                        Button {
                            Task { await select(code: item.code, name: item.nameKr) }
                            inputQty = String(item.holdingQty)
                        } label: {
                            HStack(spacing: 4) {
                                Text(item.nameKr)
                                Text("\(fmt(item.holdingQty))주").foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(item.code == code ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 입력

    private var inputs: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("유형").font(.caption).foregroundStyle(.secondary)
                ForEach(OrderType.allCases) { t in
                    Button {
                        orderType = t
                        if t == .market { inputPrice = "" }
                        else if let p = currentPrice { inputPrice = String(p.price); refreshBuyable() }
                    } label: {
                        Text(t.label).frame(width: 64).padding(.vertical, 5)
                            .background(orderType == t ? Color.accentColor : Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(orderType == t ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(spacing: 8) {
                stepperRow("단가", unit: "원", text: $inputPrice, field: .price, disabled: orderType == .market,
                           placeholder: orderType == .market ? "시장가" : "주문 단가") { up in
                    if let p = Int(inputPrice) {
                        inputPrice = String(stepPrice(p, up: up))
                        refreshBuyable()
                    }
                }
                stepperRow("수량", unit: "주", text: $inputQty, field: .qty, disabled: false, placeholder: "주문 수량") { up in
                    let q = Int(inputQty) ?? 0
                    inputQty = String(up ? q + 1 : max(1, q - 1))
                }
            }
        }
    }

    private func stepperRow(_ label: String, unit: String, text: Binding<String>, field: Field, disabled: Bool,
                            placeholder: String, step: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            Button { step(false) } label: { Image(systemName: "minus") }.disabled(disabled)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focus, equals: field)
                .disabled(disabled)
                .onChange(of: text.wrappedValue) { v in
                    let digits = v.filter(\.isNumber)
                    if digits != v { text.wrappedValue = digits }
                }
            Button { step(true) } label: { Image(systemName: "plus") }.disabled(disabled)
            Text(unit).foregroundStyle(.secondary)
        }
        .onChange(of: focus) { f in
            // 단가 입력을 마치면 그 가격 기준으로 매수 가능 수량을 갱신한다.
            if field == .price, f != .price { refreshBuyable() }
        }
    }

    private var quickRow: some View {
        HStack {
            ForEach([10, 25, 50, 100], id: \.self) { pct in
                Button("\(pct)%") { setQty(percent: pct) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if orderType == .limit, let p = currentPrice {
                    Text("현재가 **\(fmt(p.price))**원")
                }
                if side == .buy, let buyable {
                    Text("매수가능 **\(fmt(buyable.maxBuyQty))**주")
                }
                if side == .sell, let h = holdings.first(where: { $0.code == code }) {
                    Text("보유 **\(fmt(h.holdingQty))**주")
                }
            }
            .font(.callout)
        }
    }

    private func banner(_ text: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack {
            Text(text)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .foregroundStyle(color)
        .padding(8)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var submitButton: some View {
        let tint: Color = modifyTarget != nil ? .orange : side == .buy ? .up : .down
        let title: String = submitting ? "처리 중…"
            : modifyTarget.map { "정정 주문 (원번호: \($0.orderNo))" } ?? (side == .buy ? "매수 주문" : "매도 주문")
        return Button { askConfirm() } label: {
            Text(title).fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(submitting || code.isEmpty)
        .opacity(submitting || code.isEmpty ? 0.5 : 1)
    }

    // MARK: 로직

    private var priceNum: Int? { Int(inputPrice) }
    private var qtyNum: Int? { Int(inputQty) }
    private var totalAmount: Int { (priceNum ?? 0) * (qtyNum ?? 0) }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        // 앱이 직전에 열어 둔 종목(없으면 삼성전자)으로 시작
        let startCode = model.orderCode.isEmpty ? prefs.last.code : model.orderCode
        let startName = model.stocks[startCode]?.nameKr ?? prefs.last.name
        Task {
            await select(code: startCode, name: startName)
            await loadHoldings()
        }
    }

    private func select(code newCode: String, name newName: String) async {
        code = newCode
        name = model.stocks[newCode]?.nameKr ?? newName
        prefs.touch(code: newCode, name: name)
        prefsStore.save(prefs)
        searchQuery = ""
        focus = nil
        currentPrice = nil
        inputPrice = ""
        buyable = nil
        resultMessage = nil
        errorMessage = nil
        model.orderStockChanged(code: newCode)

        guard let client = model.client else { return }
        priceLoading = true
        defer { priceLoading = false }
        async let price = try? client.price(code: newCode)
        async let book = try? client.askingPrice(code: newCode)
        let (p, ob) = await (price, book)
        guard code == newCode else { return }   // 그 사이 다른 종목을 골랐으면 버린다
        if let p = p {
            currentPrice = p
            if orderType == .limit, modifyTarget == nil || inputPrice.isEmpty {
                inputPrice = String(p.price)
                refreshBuyable()
            }
        }
        if let ob = ob { model.setInitialOrderBook(ob) }
    }

    private func loadHoldings() async {
        guard let client = model.client, model.account.hasTradingAccount else { return }
        if let r = try? await client.balance() { holdings = r.assets }
    }

    private func refreshBuyable() {
        guard side == .buy, !code.isEmpty, let price = priceNum, price > 0, let client = model.client else { return }
        let target = code
        Task {
            if let info = try? await client.buyable(code: target, price: price), code == target { buyable = info }
        }
    }

    private func setQty(percent: Int) {
        let ratio = Double(percent) / 100
        if side == .buy, let buyable {
            inputQty = String(Int(Double(buyable.maxBuyQty) * ratio))
        } else if side == .sell, let h = holdings.first(where: { $0.code == code }) {
            inputQty = String(Int(Double(h.holdingQty) * ratio))
        }
    }

    private func askConfirm() {
        errorMessage = nil
        resultMessage = nil
        guard !code.isEmpty else { errorMessage = "종목을 선택해주세요."; return }
        guard let qty = qtyNum, qty > 0 else { errorMessage = "수량을 입력해주세요."; return }
        let sideText = side == .buy ? "매수" : "매도"
        if orderType == .market {
            confirmMessage = "[\(name)] \(sideText) 시장가 \(fmt(qty))주 주문하시겠습니까?"
        } else {
            guard let price = priceNum, price > 0 else { errorMessage = "단가를 입력해주세요."; return }
            confirmMessage = "[\(name)] \(sideText) \(fmt(price))원 × \(fmt(qty))주 = \(fmt(price * qty))원\n주문하시겠습니까?"
        }
    }

    private func submit() async {
        guard let client = model.client, let qty = qtyNum else { return }
        let price = orderType == .market ? 0 : (priceNum ?? 0)
        submitting = true
        defer { submitting = false }
        do {
            if let target = modifyTarget {
                let r = try await client.modifyOrder(orderNo: target.orderNo, exchange: target.exchange, qty: qty, price: price)
                resultMessage = "✅ 정정 완료! 주문번호: \(r.orderNo)"
                modifyTarget = nil
            } else {
                let r = try await client.placeOrder(OrderRequest(code: code, side: side, type: orderType, qty: qty, price: price))
                resultMessage = "✅ 주문 완료! 주문번호: \(r.orderNo)"
            }
            inputQty = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 호가창

private struct OrderBookPanel: View {
    @EnvironmentObject var model: AppModel
    let currentPrice: KisPrice?
    let hasCode: Bool
    let onPick: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("호가").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).padding(6)
            Divider()
            if !hasCode {
                placeholder("종목을 선택하세요")
            } else if let book = model.orderBook {
                table(book)
            } else {
                placeholder("호가 수신 대기 중…")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 위 = 높은 가격. 가격 0 인 빈 호가는 현재가에서 먼 쪽으로 보낸다.
    static func order(_ levels: [OrderBookLevel]) -> [OrderBookLevel] {
        levels.sorted { a, b in
            if a.price == 0 || b.price == 0 { return a.price == 0 && b.price != 0 }
            return a.price > b.price
        }
    }

    private func table(_ book: OrderBook) -> some View {
        let asks = Self.order(book.asks)
        // 매수 호가는 0 이 아래로
        let bids = Self.order(book.bids).sorted { a, b in
            if a.price == 0 || b.price == 0 { return a.price != 0 && b.price == 0 }
            return a.price > b.price
        }
        let maxQty = max((book.asks + book.bids).map(\.qty).max() ?? 1, 1)

        return VStack(spacing: 0) {
            ForEach(Array(asks.enumerated()), id: \.offset) { _, level in
                row(level, maxQty: maxQty, tint: .down, qtyFirst: true)
            }
            HStack {
                if let p = currentPrice {
                    let c = formatChange(change: p.change, sign: p.sign, rate: nil)
                    Text(fmt(p.price)).fontWeight(.bold)
                    Text(c.text).font(.caption)
                } else {
                    Text("—")
                }
            }
            .foregroundStyle(color(for: currentPrice?.direction ?? .flat))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))
            ForEach(Array(bids.enumerated()), id: \.offset) { _, level in
                row(level, maxQty: maxQty, tint: .up, qtyFirst: false)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ level: OrderBookLevel, maxQty: Int, tint: Color, qtyFirst: Bool) -> some View {
        let qty = ZStack(alignment: qtyFirst ? .trailing : .leading) {
            GeometryReader { geo in
                tint.opacity(0.18)
                    .frame(width: geo.size.width * min(1, CGFloat(level.qty) / CGFloat(maxQty)))
                    .frame(maxWidth: .infinity, alignment: qtyFirst ? .trailing : .leading)
            }
            Text(fmt(level.qty)).font(.caption).padding(.horizontal, 4)
        }
        let price = Text(fmt(level.price)).foregroundStyle(tint).frame(maxWidth: .infinity, alignment: qtyFirst ? .leading : .trailing).padding(.horizontal, 6)
        return Button { if level.price > 0 { onPick(level.price) } } label: {
            HStack(spacing: 0) {
                if qtyFirst { qty; price } else { price; qty }
            }
            .monospacedDigit()
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

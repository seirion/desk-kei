import DeskKeiCore
import SwiftUI

private enum FuturesField { case price, qty }

/// 주식선물옵션 화면: 기초자산 검색 → 선물/콜/풋·만기·행사가 선택 → 시세·호가 확인 → 주문.
/// 시세는 이 탭을 보는 동안 1초마다 REST 로 조회하고, 호가는 실시간(최대 10호가)으로 받는다.
struct FuturesView: View {
    @EnvironmentObject var model: AppModel

    @State private var prefs = JSONStore("futures.json").load(FuturesPrefsFile.self) ?? FuturesPrefsFile()
    private let prefsStore = JSONStore("futures.json")

    @State private var instrument: FuturesInstrument?
    @State private var quote: FuturesQuote?
    @State private var book: OrderBook?
    /// 이 종목의 실시간 호가를 한 번이라도 받았는지. 받기 전에는 REST 호가로 채운다.
    @State private var liveBookReceived = false
    @State private var loadError: String?
    @State private var needsPriceInit = false

    @State private var side: OrderSide = .buy
    @State private var orderType: OrderType = .limit
    @State private var inputPrice = ""
    @State private var inputQty = ""
    @FocusState private var focus: FuturesField?

    @State private var submitting = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?
    @State private var confirmMessage: String?

    private struct PollKey: Hashable {
        let active: Bool
        let code: String
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            OrderBookTable(book: book, currentPrice: quote?.price, hasCode: instrument != nil, hideEmptyLevels: true) { inputPrice = String($0) }
                .frame(width: 240)
            Divider()
            ScrollView {
                form.padding(16)
            }
        }
        .onAppear(perform: restoreIfNeeded)
        .onChange(of: model.futures.instruments.count) { _ in restoreIfNeeded() }
        .onReceive(model.live.$futuresBook.compactMap { $0 }) { live in
            guard live.code == instrument?.code else { return }
            book = live.trimmingEmptyDeepLevels()
            liveBookReceived = true
        }
        .task(id: PollKey(active: model.tab == .futures, code: instrument?.code ?? "")) {
            guard model.tab == .futures, instrument != nil else { return }
            // 탭에 다시 들어오면 호가를 새로 구독하므로, 실시간 호가가 올 때까지 REST 로 채운다.
            liveBookReceived = false
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .task(id: resultMessage) {
            guard resultMessage != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { resultMessage = nil }
        }
        .alert("주문 확인", isPresented: Binding(get: { confirmMessage != nil }, set: { if !$0 { confirmMessage = nil } })) {
            Button("주문") { Task { await submit() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text(confirmMessage ?? "")
        }
    }

    // MARK: 레이아웃

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                sideButton(.buy, "매수", .up)
                sideButton(.sell, "매도", .down)
            }
            search
            if let instrument {
                contractPickers(instrument)
                header(instrument)
            } else if model.futures.isEmpty {
                Text("선물옵션 종목을 불러오는 중입니다…").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("기초자산(종목명 또는 코드)을 검색해 선택하세요.").font(.callout).foregroundStyle(.secondary)
            }
            inputs
            quickRow
            if orderType == .limit, let notional = notionalAmount {
                HStack(spacing: 0) {
                    Text("명목금액 ")
                    Text(fmt(notional)).bold()
                    Text("원")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let resultMessage { banner(resultMessage, color: .green) { self.resultMessage = nil } }
            if let errorMessage { banner(errorMessage, color: .up) { self.errorMessage = nil } }
            submitButton
        }
    }

    private func sideButton(_ s: OrderSide, _ label: String, _ tint: Color) -> some View {
        Button { side = s } label: {
            Text(label).fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 8)
                .foregroundStyle(side == s ? Color.white : tint)
                .background(side == s ? tint : tint.opacity(0.1))
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 종목 검색 / 선택

    private var recentItems: [RecentStock] {
        prefs.recent.filter { model.futures.byCode[$0.code] != nil }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 8) {
            StockSearchField(
                selectedCode: instrument?.code ?? "", recent: recentItems, onRemoveRecent: removeRecent,
                source: { q in model.futures.search(q, limit: 40).map { (code: $0.key, name: $0.name) } }
            ) { code, _ in pick(code: code) }
            RecentStockChips(selectedCode: instrument?.code ?? "", recent: recentItems, maxChipWidth: 160) { code, _ in pick(code: code) }
        }
    }

    private func contractPickers(_ ins: FuturesInstrument) -> some View {
        let catalog = model.futures
        let expiries = catalog.expiries(underlying: ins.underlyingCode, kind: ins.kind)
        let strikes = ins.kind.isOption ? catalog.strikes(underlying: ins.underlyingCode, kind: ins.kind, expiry: ins.expiry) : []
        return HStack(spacing: 10) {
            Picker("종류", selection: Binding(get: { ins.kind }, set: { resolve(kind: $0) })) {
                ForEach(FuturesKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Picker("만기", selection: Binding(get: { ins.expiry }, set: { resolve(expiry: $0) })) {
                ForEach(expiries, id: \.self) { Text(FuturesInstrument.expiryLabel($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("만기 월")

            if ins.kind.isOption {
                Picker("행사가", selection: Binding(get: { ins.strike }, set: { resolve(strike: $0) })) {
                    ForEach(strikes, id: \.self) { Text(fmt($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("행사가")
            }
            Spacer(minLength: 0)
        }
    }

    private func header(_ ins: FuturesInstrument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ins.title).font(.title3).fontWeight(.bold)
                Text(ins.code).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let p = quote?.price {
                    let c = formatChange(change: p.change, sign: p.sign, rate: nil)
                    Text("\(fmt(p.price))원 \(c.text) (\(String(format: "%.2f", p.rate))%)")
                        .foregroundStyle(color(for: c.direction)).fontWeight(.semibold).monospacedDigit()
                } else if loadError == nil {
                    Text("조회 중…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(Color.up)
            }
            if let q = quote {
                HStack(spacing: 14) {
                    item("시", fmt(q.price.open), .primary)
                    item("고", fmt(q.price.high), .up)
                    item("저", fmt(q.price.low), .down)
                    item("량", formatVolume(q.price.volume), .primary)
                }
                .font(.callout).monospacedDigit()
                HStack(spacing: 14) {
                    info("상한", fmt(q.upperLimit))
                    info("하한", fmt(q.lowerLimit))
                    info("미결제", fmt(q.openInterest))
                    if q.theoreticalPrice > 0 { info("이론가", fmt(q.theoreticalPrice)) }
                }
                .font(.caption).monospacedDigit()
                HStack(spacing: 14) {
                    if let date = lastTradeDateLabel(q.lastTradeDate) { info("최종거래일", "\(date) (D-\(q.remainingDays))") }
                    if ins.multiplier > 0 { info("승수", "\(ins.multiplier)") }
                }
                .font(.caption).monospacedDigit()
            }
        }
    }

    private func item(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(tint == .primary ? Color.secondary : tint).font(.caption)
            Text(value).foregroundStyle(tint)
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func lastTradeDateLabel(_ ymd: String) -> String? {
        guard ymd.count == 8 else { return nil }
        return "\(ymd.prefix(4)).\(ymd.dropFirst(4).prefix(2)).\(ymd.suffix(2))"
    }

    // MARK: 입력

    private var tick: Int { inferTick(book) }

    private var inputs: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("유형").font(.caption).foregroundStyle(.secondary)
                ForEach(OrderType.allCases) { t in
                    Button {
                        orderType = t
                        if t == .market { inputPrice = "" } else if inputPrice.isEmpty { fillReferencePrice() }
                    } label: {
                        Text(t.label).frame(width: 64).padding(.vertical, 5)
                            .background(orderType == t ? Color.accentColor : Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(orderType == t ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    // 옵션은 시장가 주문을 지원하지 않는 것으로 보고 지정가만 쓴다.
                    .disabled(t == .market && (instrument?.kind.isOption ?? false))
                }
            }
            VStack(spacing: 8) {
                stepperRow("단가", unit: "원", text: $inputPrice, field: .price, disabled: orderType == .market,
                           placeholder: orderType == .market ? "시장가" : "주문 단가") { up in
                    if let p = Int(inputPrice) { inputPrice = String(stepPrice(p, up: up, tick: tick)) }
                }
                stepperRow("수량", unit: "계약", text: $inputQty, field: .qty, disabled: false, placeholder: "주문 수량") { up in
                    let q = Int(inputQty) ?? 0
                    inputQty = String(up ? q + 1 : max(1, q - 1))
                }
            }
        }
    }

    private func stepperRow(_ label: String, unit: String, text: Binding<String>, field: FuturesField, disabled: Bool,
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
            Text(unit).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
        }
    }

    private var quickRow: some View {
        HStack {
            ForEach([1, 2, 5, 10], id: \.self) { qty in
                Button("\(qty)계약") { inputQty = String(qty) }
            }
            Spacer()
            if let p = quote?.price, p.price > 0 {
                HStack(spacing: 0) {
                    Text("현재가 ")
                    Text(fmt(p.price)).bold()
                    Text("원")
                }
                .font(.callout)
            }
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
        let tint: Color = side == .buy ? .up : .down
        let title = submitting ? "처리 중…" : (side == .buy ? "매수 주문" : "매도 주문")
        let disabled = submitting || instrument == nil
        return Button { askConfirm() } label: {
            Text(title).fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    // MARK: 종목 선택 로직

    private func restoreIfNeeded() {
        guard instrument == nil, !model.futures.isEmpty else { return }
        if let last = prefs.last, let ins = model.futures.byCode[last.code] {
            select(ins)
        } else if let samsung = model.futures.underlyings.first(where: { $0.code == "005930" }) {
            selectUnderlying(samsung.code)
        }
    }

    private func pick(code: String) {
        if let underlying = FuturesCatalog.underlyingCode(fromKey: code) {
            selectUnderlying(underlying)
        } else if let ins = model.futures.byCode[code] {
            select(ins)
        }
    }

    /// 기초자산을 고르면 가장 가까운 만기의 선물로 시작한다. 선물이 없으면 가장 가까운 만기의 첫 종목.
    private func selectUnderlying(_ code: String) {
        let catalog = model.futures
        if let expiry = catalog.expiries(underlying: code, kind: .future).first,
           let ins = catalog.instrument(underlying: code, kind: .future, expiry: expiry, strike: 0) {
            select(ins)
        } else if let first = catalog.instruments(underlying: code).min(by: { ($0.expiry, $0.strike) < ($1.expiry, $1.strike) }) {
            select(first)
        }
    }

    /// 종류·만기·행사가 중 바뀐 것만 반영해 같은 기초자산의 다른 종목으로 옮긴다.
    /// 그 조합에 없는 만기·행사가는 가장 가까운 것으로 맞춘다.
    private func resolve(kind: FuturesKind? = nil, expiry: String? = nil, strike: Int? = nil) {
        guard let cur = instrument else { return }
        let catalog = model.futures
        let k = kind ?? cur.kind
        let expiries = catalog.expiries(underlying: cur.underlyingCode, kind: k)
        guard let nearest = expiries.first else { return }
        let e = expiry ?? (expiries.contains(cur.expiry) ? cur.expiry : nearest)
        var s = 0
        if k.isOption {
            let strikes = catalog.strikes(underlying: cur.underlyingCode, kind: k, expiry: e)
            guard !strikes.isEmpty else { return }
            // 선물에서 옵션으로 옮길 때는 현재가에 가까운 행사가로 시작한다.
            let want = strike ?? (cur.strike > 0 ? cur.strike : (quote?.price.price ?? strikes[strikes.count / 2]))
            s = strikes.min { abs($0 - want) < abs($1 - want) } ?? want
        }
        if let ins = catalog.instrument(underlying: cur.underlyingCode, kind: k, expiry: e, strike: s) { select(ins) }
    }

    private func select(_ ins: FuturesInstrument) {
        guard ins != instrument else { return }
        instrument = ins
        quote = nil
        book = nil
        liveBookReceived = false
        loadError = nil
        inputPrice = ""
        resultMessage = nil
        errorMessage = nil
        focus = nil
        if ins.kind.isOption { orderType = .limit }
        needsPriceInit = orderType == .limit
        prefs.touch(code: ins.code, name: ins.title)
        prefsStore.save(prefs)
        model.futuresInstrumentChanged(ins)
    }

    private func removeRecent(code: String) {
        prefs.removeRecent(code: code)
        prefsStore.save(prefs)
    }

    // MARK: 조회

    private func refresh() async {
        guard let ins = instrument, let client = model.client else { return }
        // 호가는 실시간으로 받는다. 받기 전(또는 소켓이 끊긴 동안)에만 REST 로 채운다.
        let needRestBook = !liveBookReceived
        async let q = fetchQuote(client, ins)
        async let b = needRestBook ? (try? await client.futuresOrderBook(code: ins.code, kind: ins.kind)) : nil
        let (newQuote, newBook) = await (q, b)
        guard instrument?.code == ins.code, !Task.isCancelled else { return }
        // 조회하는 사이 실시간 호가가 왔다면 그것이 더 최신이다.
        if let newBook, !liveBookReceived { book = newBook.trimmingEmptyDeepLevels() }
        switch newQuote {
        case .success(let value):
            quote = value
            loadError = nil
            if needsPriceInit { fillReferencePrice() }
        case .failure(let error):
            // 초당 거래건수 제한은 다음 주기에 다시 시도하면 되므로 알리지 않는다.
            if !error.message.contains("초당") { loadError = error.message }
        }
    }

    private func fetchQuote(_ client: KisClient, _ ins: FuturesInstrument) async -> Result<FuturesQuote, KisError> {
        do {
            guard let q = try await client.futuresQuote(code: ins.code, kind: ins.kind) else {
                return .failure(KisError("시세를 조회하지 못했습니다."))
            }
            return .success(q)
        } catch {
            return .failure((error as? KisError) ?? KisError(error.localizedDescription))
        }
    }

    /// 단가 칸이 비어 있으면 현재가(거래가 없으면 전일 종가)로 채운다.
    private func fillReferencePrice() {
        guard let p = quote?.price else { return }
        let ref = p.price > 0 ? p.price : p.prevPrice
        guard ref > 0 else { return }
        needsPriceInit = false
        if orderType == .limit, inputPrice.isEmpty { inputPrice = String(ref) }
    }

    // MARK: 주문

    private var priceNum: Int? { Int(inputPrice) }
    private var qtyNum: Int? { Int(inputQty) }

    /// 지정가 × 수량 × 승수. 승수를 모르면 nil.
    private var notionalAmount: Int? {
        guard let ins = instrument, ins.multiplier > 0, let price = priceNum, let qty = qtyNum, price > 0, qty > 0 else { return nil }
        return price * qty * ins.multiplier
    }

    private func askConfirm() {
        errorMessage = nil
        resultMessage = nil
        guard let ins = instrument else { errorMessage = "종목을 선택해주세요."; return }
        guard let qty = qtyNum, qty > 0 else { errorMessage = "수량을 입력해주세요."; return }
        let sideText = side == .buy ? "매수" : "매도"
        let message: String
        if orderType == .market {
            message = "[\(ins.title)] \(sideText) 시장가 \(fmt(qty))계약 주문하시겠습니까?"
        } else {
            guard let price = priceNum, price > 0 else { errorMessage = "단가를 입력해주세요."; return }
            var text = "[\(ins.title)] \(sideText) \(fmt(price))원 × \(fmt(qty))계약"
            if let notional = notionalAmount { text += " (명목 \(fmt(notional))원)" }
            message = text + "\n주문하시겠습니까?"
        }
        if model.confirmOrders {
            confirmMessage = message
        } else {
            Task { await submit() }
        }
    }

    private func submit() async {
        guard let client = model.client, let ins = instrument, let qty = qtyNum else { return }
        let price = orderType == .market ? 0 : (priceNum ?? 0)
        submitting = true
        defer { submitting = false }
        do {
            let r = try await client.placeFuturesOrder(
                FuturesOrderRequest(code: ins.code, side: side, type: orderType, qty: qty, price: price))
            resultMessage = "✅ 주문 완료! 주문번호: \(r.orderNo)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import Foundation

/// 한국투자증권 Open API REST 클라이언트. 프록시 없이 직접 호출한다.
public final class KisClient {
    public static let baseURL = URL(string: "https://openapi.koreainvestment.com:9443")!

    private let account: KisAccount
    private let session: URLSession
    private let tokenStore: JSONStore

    public init(account: KisAccount, session: URLSession = .shared, tokenStore: JSONStore = JSONStore("tokens.json")) {
        self.account = account
        self.session = session
        self.tokenStore = tokenStore
    }

    // MARK: - 인증

    private var tokenKey: String { String(account.appKey.prefix(12)) }

    /// 계정(appKey)별로 캐시된 토큰을 쓰고, 만료되면 새로 발급한다.
    public func accessToken() async throws -> String {
        guard account.hasCredentials else { throw KisError.notConfigured }
        var cache = tokenStore.load([String: CachedToken].self) ?? [:]
        if let t = cache[tokenKey], t.expiresAt > Date() { return t.accessToken }

        let json = try await send(path: "/oauth2/tokenP", method: "POST", body: [
            "grant_type": "client_credentials",
            "appkey": account.appKey,
            "appsecret": account.appSecret,
        ], headers: [:])
        guard let token = json["access_token"] as? String else {
            throw KisError(json["error_description"] as? String ?? "토큰 발급 실패")
        }
        let expiresIn = (json["expires_in"] as? Int) ?? 86_400
        cache[tokenKey] = CachedToken(accessToken: token, expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn - 60)))
        tokenStore.save(cache)
        return token
    }

    /// WebSocket 접속용 approval key
    public func approvalKey() async throws -> String {
        guard account.hasCredentials else { throw KisError.notConfigured }
        let json = try await send(path: "/oauth2/Approval", method: "POST", body: [
            "grant_type": "client_credentials",
            "appkey": account.appKey,
            "secretkey": account.appSecret,
        ], headers: [:])
        guard let key = json["approval_key"] as? String else {
            throw KisError(json["error_description"] as? String ?? "Approval key 발급 실패")
        }
        return key
    }

    // MARK: - 시세

    /// 현재가. market: J=KRX, NX=NXT
    public func price(code: String, market: String = "J") async throws -> KisPrice? {
        let json = try await call(path: "/uapi/domestic-stock/v1/quotations/inquire-price", trId: "FHKST01010100", query: [
            "FID_COND_MRKT_DIV_CODE": market,
            "FID_INPUT_ISCD": code,
        ])
        guard isOK(json), let o = json["output"] as? [String: Any] else { return nil }
        return KisPrice(
            price: int(o["stck_prpr"]),
            prevPrice: int(o["stck_sdpr"]),
            change: abs(int(o["prdy_vrss"])),
            sign: str(o["prdy_vrss_sign"]),
            rate: abs(double(o["prdy_ctrt"])),
            open: int(o["stck_oprc"]),
            high: int(o["stck_hgpr"]),
            low: int(o["stck_lwpr"]),
            volume: int(o["acml_vol"])
        )
    }

    /// 여러 종목 현재가를 순차 조회 (초당 20건 제한 대응 딜레이 포함)
    public func prices(codes: [String], market: String = "J", onResult: @escaping (String, KisPrice) -> Void) async {
        for code in codes {
            if Task.isCancelled { return }
            if let p = try? await price(code: code, market: market) { onResult(code, p) }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// 호가 (REST, 초기 1회 표시용)
    public func askingPrice(code: String, market: String = "J") async throws -> OrderBook? {
        let json = try await call(path: "/uapi/domestic-stock/v1/quotations/inquire-asking-price-exp-ccn", trId: "FHKST01010200", query: [
            "FID_COND_MRKT_DIV_CODE": market,
            "FID_INPUT_ISCD": code,
        ])
        guard isOK(json), let o = json["output1"] as? [String: Any] else { return nil }
        var asks: [OrderBookLevel] = []
        var bids: [OrderBookLevel] = []
        for i in 1...10 {
            asks.append(OrderBookLevel(price: int(o["askp\(i)"]), qty: int(o["askp_rsqn\(i)"])))
            bids.append(OrderBookLevel(price: int(o["bidp\(i)"]), qty: int(o["bidp_rsqn\(i)"])))
        }
        return OrderBook(code: code, asks: asks, bids: bids)
    }

    /// 오늘의 1분봉(08:00~20:00). KRX(정규장·애프터마켓) 에 NXT 프리마켓(08:00~09:00)을 이어 붙인다.
    /// 호출 한 번에 120개씩 시간을 거슬러 올라가며 받는다.
    public func minuteBars(code: String) async throws -> [MinuteBar] {
        let main = try await minutePages(code: code, market: "J", from: "235959", stopAt: 9 * 60)
        try? await Task.sleep(nanoseconds: 60_000_000)
        let pre = try await minutePages(code: code, market: "NX", from: "085959", stopAt: MinuteChart.startMinute)
        return MinuteChart.merge(pre + main)
    }

    private func minutePages(code: String, market: String, from: String, stopAt: Int) async throws -> [MinuteBar] {
        let today = MarketClock.todayString()
        var hour = from
        var bars: [MinuteBar] = []
        for _ in 0..<8 {
            let json = try await withRateLimitRetry {
                let json = try await self.call(path: "/uapi/domestic-stock/v1/quotations/inquire-time-dailychartprice", trId: "FHKST03010230", query: [
                    "FID_COND_MRKT_DIV_CODE": market,
                    "FID_INPUT_ISCD": code,
                    "FID_INPUT_HOUR_1": hour,
                    "FID_INPUT_DATE_1": today,
                    "FID_PW_DATA_INCU_YN": "N",
                    "FID_FAKE_TICK_INCU_YN": "",
                ])
                try self.check(json, fallback: "분봉 조회 오류")
                return json
            }
            let rows = (json["output2"] as? [[String: Any]]) ?? []
            guard let last = rows.last.map({ str($0["stck_cntg_hour"]) }), last < hour else { break }
            bars += MinuteChart.bars(from: rows, date: today)
            let lastMinute = (Int(last.prefix(2)) ?? 0) * 60 + (Int(last.dropFirst(2).prefix(2)) ?? 0)
            if rows.count < 120 || lastMinute <= stopAt { break }
            hour = last
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return bars
    }

    /// 초당 거래건수 제한에 걸리면 잠시 기다렸다가 다시 시도한다.
    private func withRateLimitRetry<T>(_ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await body() }
            catch let error as KisError where error.message.contains("초당") && attempt < 4 {
                attempt += 1
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    // MARK: - 잔고

    public func balance() async throws -> (assets: [AssetItem], summary: AccountSummary) {
        guard account.hasTradingAccount else { throw KisError.notConfigured }
        let (cano, prdt) = account.accountParts
        var assets: [AssetItem] = []
        var summary = AccountSummary()
        var fk = "", nk = ""

        while true {
            let json = try await call(path: "/uapi/domestic-stock/v1/trading/inquire-balance", trId: "TTTC8434R", query: [
                "CANO": cano, "ACNT_PRDT_CD": prdt,
                "AFHR_FLPR_YN": "N", "OFL_YN": "", "INQR_DVSN": "02", "UNPR_DVSN": "01",
                "FUND_STTL_ICLD_YN": "N", "FNCG_AMT_AUTO_RDPT_YN": "N", "PRCS_DVSN": "00",
                "CTX_AREA_FK100": fk, "CTX_AREA_NK100": nk,
            ])
            try check(json, fallback: "잔고 조회 오류")

            for item in (json["output1"] as? [[String: Any]]) ?? [] {
                let qty = int(item["hldg_qty"])
                if qty <= 0 { continue }
                assets.append(AssetItem(
                    code: str(item["pdno"]),
                    nameKr: str(item["prdt_name"]),
                    holdingQty: qty,
                    purchaseAvgPrice: double(item["pchs_avg_pric"]),
                    purchaseAmount: int(item["pchs_amt"]),
                    currentPrice: int(item["prpr"]),
                    priceChange: int(item["bfdy_cprs_icdc"]),
                    priceChangeRate: double(item["fltt_rt"]),
                    evaluationAmount: int(item["evlu_amt"]),
                    profitLossAmount: int(item["evlu_pfls_amt"]),
                    profitLossRate: double(item["evlu_pfls_rt"])
                ))
            }

            if let d = (json["output2"] as? [[String: Any]])?.first {
                summary.depositAmount = int(d["prvs_rcdl_excc_amt"])
                summary.stockEvaluationAmount = int(d["scts_evlu_amt"])
                summary.totalEvaluationAmount = int(d["tot_evlu_amt"])
                summary.purchaseAmountTotal = int(d["pchs_amt_smtl_amt"])
                summary.profitLossTotal = int(d["evlu_pfls_smtl_amt"])
                summary.netAssetAmount = int(d["nass_amt"])
            }

            let nextFk = str(json["ctx_area_fk100"]).trimmingCharacters(in: .whitespaces)
            let nextNk = str(json["ctx_area_nk100"]).trimmingCharacters(in: .whitespaces)
            if !nextFk.isEmpty, !nextNk.isEmpty, nextFk != fk || nextNk != nk {
                fk = nextFk
                nk = nextNk
            } else {
                break
            }
        }
        return (assets, summary)
    }

    // MARK: - 주문

    public func placeOrder(_ req: OrderRequest) async throws -> OrderResult {
        guard account.hasTradingAccount else { throw KisError.notConfigured }
        if req.type == .market, MarketClock.isKrxAfterMarket() {
            throw KisError("애프터마켓(16:00~20:00)에는 시장가 주문을 할 수 없습니다.")
        }
        let (cano, prdt) = account.accountParts
        let json = try await call(
            path: "/uapi/domestic-stock/v1/trading/order-cash",
            method: "POST",
            trId: req.side == .buy ? "TTTC0802U" : "TTTC0801U",
            body: [
                "CANO": cano, "ACNT_PRDT_CD": prdt,
                "PDNO": req.code,
                "EXCG_ID_DVSN_CD": "KRX",
                "ORD_DVSN": req.type == .market ? OrderType.market.rawValue : MarketClock.limitOrderDivision(),
                "ORD_QTY": String(req.qty),
                "ORD_UNPR": String(req.type == .market ? 0 : req.price),
            ])
        try check(json, fallback: "주문 오류")
        let o = json["output"] as? [String: Any] ?? [:]
        return OrderResult(orderNo: str(o["KRX_FWDG_ORD_ORGNO"]) + str(o["ODNO"]), time: str(o["ORD_TMD"]))
    }

    /// 매수 가능 수량/금액
    public func buyable(code: String, price: Int) async throws -> BuyableInfo {
        guard account.hasTradingAccount else { throw KisError.notConfigured }
        let (cano, prdt) = account.accountParts
        let json = try await call(path: "/uapi/domestic-stock/v1/trading/inquire-psbl-order", trId: "TTTC8908R", query: [
            "CANO": cano, "ACNT_PRDT_CD": prdt,
            "PDNO": code,
            "ORD_UNPR": String(price),
            "ORD_DVSN": price == 0 ? "01" : "00",
            "CMA_EVLU_AMT_ICLD_YN": "N",
            "OVRS_ICLD_YN": "N",
        ])
        try check(json, fallback: "매수가능조회 오류")
        let o = json["output"] as? [String: Any] ?? [:]
        return BuyableInfo(maxBuyQty: int(o["max_buy_qty"]), buyableAmount: int(o["ord_psbl_cash"]))
    }

    /// 미체결 주문 정정
    public func modifyOrder(orderNo: String, exchange: String, qty: Int, price: Int) async throws -> OrderResult {
        guard account.hasTradingAccount else { throw KisError.notConfigured }
        let (cano, prdt) = account.accountParts
        let json = try await call(
            path: "/uapi/domestic-stock/v1/trading/order-rvsecncl",
            method: "POST",
            trId: "TTTC0803U",
            body: [
                "CANO": cano, "ACNT_PRDT_CD": prdt,
                "KRX_FWDG_ORD_ORGNO": "",
                "ORGN_ODNO": orderNo,
                "EXCG_ID_DVSN_CD": exchange.isEmpty ? "KRX" : exchange,
                "ORD_DVSN": price > 0 ? MarketClock.limitOrderDivision() : "01",
                "RVSE_CNCL_DVSN_CD": "01",
                "ORD_QTY": String(qty),
                "ORD_UNPR": String(price),
                "QTY_ALL_ORD_YN": "Y",
            ])
        try check(json, fallback: "정정 오류")
        let o = json["output"] as? [String: Any] ?? [:]
        return OrderResult(orderNo: str(o["ODNO"]), time: str(o["ORD_TMD"]))
    }

    /// 당일 주문/체결 내역
    public func dailyOrders(_ filter: CcldFilter = .all) async throws -> [DailyOrderItem] {
        guard account.hasTradingAccount else { throw KisError.notConfigured }
        let (cano, prdt) = account.accountParts
        let today = MarketClock.todayString()
        var items: [DailyOrderItem] = []
        var fk = "", nk = ""

        while true {
            let json = try await call(path: "/uapi/domestic-stock/v1/trading/inquire-daily-ccld", trId: "TTTC8001R", query: [
                "CANO": cano, "ACNT_PRDT_CD": prdt,
                "INQR_STRT_DT": today, "INQR_END_DT": today,
                "SLL_BUY_DVSN_CD": "00", "INQR_DVSN": "01", "PDNO": "",
                "CCLD_DVSN": filter.rawValue,
                "ORD_GNO_BRNO": "", "ODNO": "", "INQR_DVSN_3": "00", "INQR_DVSN_1": "",
                "CTX_AREA_FK100": fk, "CTX_AREA_NK100": nk,
            ])
            try check(json, fallback: "주문내역 오류")

            for o in (json["output1"] as? [[String: Any]]) ?? [] {
                items.append(DailyOrderItem(
                    orderNo: str(o["odno"]),
                    code: str(o["pdno"]),
                    nameKr: str(o["prdt_name"]),
                    side: str(o["sll_buy_dvsn_cd"]) == "02" ? .buy : .sell,
                    orderQty: int(o["ord_qty"]),
                    orderPrice: int(o["ord_unpr"]),
                    execQty: int(o["tot_ccld_qty"]),
                    execAvgPrice: double(o["avg_prvs"]),
                    execAmount: int(o["tot_ccld_amt"]),
                    remainQty: int(o["rmn_qty"]),
                    orderTime: str(o["ord_tmd"]),
                    status: str(o["ord_stts"]),
                    orderType: str(o["ord_dvsn_name"]),
                    exchange: str(o["excg_id_dvsn_cd"])
                ))
            }

            let nextFk = str(json["ctx_area_fk100"]).trimmingCharacters(in: .whitespaces)
            let nextNk = str(json["ctx_area_nk100"]).trimmingCharacters(in: .whitespaces)
            if !nextFk.isEmpty, !nextNk.isEmpty, nextFk != fk || nextNk != nk {
                fk = nextFk
                nk = nextNk
            } else {
                break
            }
        }
        return items
    }

    // MARK: - 전송

    private func call(path: String, method: String = "GET", trId: String,
                      query: [String: String] = [:], body: [String: String]? = nil) async throws -> [String: Any] {
        let token = try await accessToken()
        return try await send(path: path, method: method, query: query, body: body, headers: [
            "authorization": "Bearer \(token)",
            "appkey": account.appKey,
            "appsecret": account.appSecret,
            "tr_id": trId,
            "custtype": "P",
        ])
    }

    private func send(path: String, method: String, query: [String: String] = [:],
                      body: [String: String]? = nil, headers: [String: String]) async throws -> [String: Any] {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, response) = try await session.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = (json?["msg1"] as? String) ?? (json?["error_description"] as? String)
            throw KisError(msg ?? "요청 실패: HTTP \(http.statusCode)")
        }
        guard let json else { throw KisError("응답을 해석할 수 없습니다.") }
        return json
    }

    private func isOK(_ json: [String: Any]) -> Bool { str(json["rt_cd"]) == "0" }

    private func check(_ json: [String: Any], fallback: String) throws {
        if !isOK(json) {
            let msg = str(json["msg1"])
            throw KisError(msg.isEmpty ? fallback : msg)
        }
    }
}

// MARK: - 값 변환

func str(_ v: Any?) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

func int(_ v: Any?) -> Int {
    if let n = v as? Int { return n }
    let s = str(v).trimmingCharacters(in: .whitespaces)
    return Int(s) ?? Int(Double(s) ?? 0)
}

func double(_ v: Any?) -> Double {
    if let d = v as? Double { return d }
    return Double(str(v).trimmingCharacters(in: .whitespaces)) ?? 0
}

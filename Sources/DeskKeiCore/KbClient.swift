import Foundation

/// KB증권 Open API 클라이언트 (https://developer.kbsec.com:32484). 인증과 잔고 조회를 지원한다.
/// 모든 TR 을 `api/v1/<tr코드 소문자>` 로 POST 하고 요청·응답이 dataHeader / dataBody 로 감싸진다.
public final class KbClient: TradingBroker {
    public static let baseURL = URL(string: "https://developer.kbsec.com:32484")!

    let account: BrokerAccount
    private let session: URLSession
    private let tokens: BrokerTokenCache

    public init(account: BrokerAccount, session: URLSession = .shared, tokenStore: JSONStore = JSONStore("tokens.json")) {
        self.account = account
        self.session = session
        self.tokens = BrokerTokenCache(store: tokenStore, key: "kb:" + String(account.appKey.prefix(12)))
    }

    // MARK: 인증

    public func verify() async throws { _ = try await accessToken() }

    func accessToken() async throws -> String {
        guard account.hasCredentials else { throw KisError.notConfigured }
        if let t = tokens.load() { return t }
        let (json, http) = try await BrokerHTTP.post(session: session, url: Self.baseURL.appendingPathComponent("oauth2/token"), headers: [:], body: Self.envelope([
            "grantType": "client_credentials",
            "appKey": account.appKey,
            "appSecret": account.appSecret,
        ]))
        let header = json["dataHeader"] as? [String: Any] ?? [:]
        let body = json["dataBody"] as? [String: Any] ?? [:]
        guard str(header["resultCode"]) == "200", let token = body["access_token"] as? String, !token.isEmpty else {
            let msg = Self.message(header)
            throw KisError(msg.isEmpty ? "KB 토큰 발급 실패: HTTP \(http.statusCode)" : "KB 토큰 오류: \(msg)")
        }
        let expiresIn = TimeInterval(BrokerNumber.int(body["expires_in"]))
        tokens.save(token, expiresAt: Date().addingTimeInterval(expiresIn > 0 ? expiresIn : 86_400))
        return token
    }

    /// 응답 헤더의 오류 문구. 처리 메시지(processMessage)를 먼저, 없으면 결과 메시지를 쓴다.
    static func message(_ header: [String: Any]) -> String {
        let process = str(header["processMessage"]).trimmingCharacters(in: .whitespaces)
        return process.isEmpty ? str(header["resultMessage"]).trimmingCharacters(in: .whitespaces) : process
    }

    static func envelope(_ body: [String: String]) -> [String: Any] {
        ["dataHeader": ["ipAddr": "127.0.0.1", "macAddr": "00:00:00:00:00:00"], "dataBody": body]
    }

    // MARK: 호출

    /// TR 한 건을 호출하고 dataBody 를 돌려준다. HTTP 401 이면 토큰을 버리고 새로 받아 한 번만 다시 시도한다.
    func call(tr: String, body: [String: String] = [:]) async throws -> [String: Any] {
        func send() async throws -> (json: [String: Any], http: HTTPURLResponse) {
            let token = try await accessToken()
            return try await BrokerHTTP.post(session: session, url: Self.baseURL.appendingPathComponent("api/v1/\(tr.lowercased())"),
                                             headers: ["Authorization": "Bearer \(token)"], body: Self.envelope(body))
        }
        var r = try await send()
        if r.http.statusCode == 401 {
            tokens.clear()
            r = try await send()
        }
        guard let header = r.json["dataHeader"] as? [String: Any] else {
            throw KisError("KB 응답을 해석할 수 없습니다: HTTP \(r.http.statusCode)")
        }
        if str(header["resultCode"]) != "200" || str(header["processFlag"]) == "B" {
            throw KisError("KB 오류: " + Self.message(header))
        }
        return r.json["dataBody"] as? [String: Any] ?? [:]
    }

    /// 다음키(nxt_key)가 비거나 그대로일 때까지 이어서 조회해 [rowsKey] 레코드를 모두 모은다.
    func callPaged(tr: String, body: [String: String], rowsKey: String, maxPages: Int = 10) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var nextKey = ""
        for _ in 0..<maxPages {
            let data = try await call(tr: tr, body: body.merging(["nxt_key": nextKey]) { a, _ in a })
            rows += (data[rowsKey] as? [[String: Any]]) ?? []
            let key = str(data["nxt_key"]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty || key == nextKey { break }
            nextKey = key
        }
        return rows
    }

    // MARK: 잔고

    public func balance() async throws -> (assets: [AssetItem], summary: AccountSummary) {
        // SSQM2952 체결기준 잔고현황 (A: 통합시세)
        let data = try await call(tr: "SSQM2952", body: ["excg_mktpr_ccd": "A"])
        return Self.makeBalance(data)
    }

    static func makeBalance(_ data: [String: Any]) -> (assets: [AssetItem], summary: AccountSummary) {
        var assets: [AssetItem] = []
        for r in (data["Record1"] as? [[String: Any]]) ?? [] {
            // 체결기준 반영 수량은 정산수량(ec_q). 보유수량(hld_q)은 결제 전 매수분이 0 으로 나온다
            let qty = BrokerNumber.int(r["ec_q"])
            guard qty > 0 else { continue }
            let avg = BrokerNumber.double(r["byng_avr_prc"])
            assets.append(AssetItem(
                code: str(r["is_cd"]).trimmingCharacters(in: .whitespaces).removingPrefix("A"),
                nameKr: str(r["is_nm"]).trimmingCharacters(in: .whitespaces),
                holdingQty: qty,
                purchaseAvgPrice: avg,
                purchaseAmount: Int((avg * Double(qty)).rounded()),
                currentPrice: BrokerNumber.int(r["now_prc"]),
                priceChange: 0,
                priceChangeRate: 0,
                evaluationAmount: BrokerNumber.int(r["val_amt"]),
                profitLossAmount: BrokerNumber.int(r["val_pl"]),
                profitLossRate: BrokerNumber.double(r["val_yld"])
            ))
        }

        var summary = AccountSummary()
        summary.stockEvaluationAmount = assets.reduce(0) { $0 + $1.evaluationAmount }
        summary.netAssetAmount = BrokerNumber.int(data["nt_asts_val_amt"])
        summary.totalEvaluationAmount = summary.netAssetAmount
        summary.purchaseAmountTotal = assets.reduce(0) { $0 + $1.purchaseAmount }
        summary.profitLossTotal = BrokerNumber.int(data["val_pl_sum"])
        // 예수금(D+2): 값이 없으면 D+0 으로 대신한다
        let d2 = BrokerNumber.int(data["nxt2_dy_tfnd"])
        summary.depositAmount = d2 != 0 ? d2 : BrokerNumber.int(data["dy_tfnd"])
        return (assets, summary)
    }
}

// MARK: - 주문

/// 앱의 거래소 구분(KRX/NXT/SOR)과 KB sor_ordr_ccd(K/N/S) 변환
enum KbExchange {
    static func toCode(_ exchange: String) -> String {
        switch exchange {
        case "KRX": return "K"
        case "NXT": return "N"
        default: return "S"
        }
    }

    static func fromCode(_ code: String) -> String {
        switch code {
        case "K": return "KRX"
        case "N": return "NXT"
        default: return "SOR"
        }
    }
}

extension KbClient {
    /// SSAM1802 매수주문 / SSAM1801 매도주문. 거래소는 KB 가 고르는 SOR(S) 로 보낸다.
    public func placeOrder(_ req: OrderRequest) async throws -> OrderResult {
        let market = req.type == .market
        let data = try await call(tr: req.side == .buy ? "SSAM1802" : "SSAM1801", body: [
            "mkt_tm_clsf": "1",
            "is_cd": req.code,
            "ordr_q": String(req.qty),
            "ordr_uprc": market ? "0" : String(req.price),
            "ordr_ccd": market ? "03" : "00",
            "sor_ordr_ccd": KbExchange.toCode("SOR"),
        ])
        return OrderResult(orderNo: str(data["ordr_no"]).trimmingCharacters(in: .whitespaces), time: MarketClock.timeString())
    }

    /// SSAM1805 정정주문. KB 는 수량을 바꾸지 않고 남은 수량 전부를 지정가로 정정한다(`qty` 는 쓰지 않는다).
    public func modify(_ item: DailyOrderItem, qty: Int, price: Int) async throws -> OrderResult {
        guard price > 0 else { throw KisError("정정할 단가를 입력해 주세요.") }
        let data = try await call(tr: "SSAM1805", body: [
            "mkt_tm_clsf": "1",
            "is_cd": item.code,
            "ordr_q": "",
            "ordr_uprc": String(price),
            "ordr_ccd": "00",
            "crct_clsf": "2",
            "orgn_ordr_no": item.orderNo,
            "sor_ordr_ccd": KbExchange.toCode(item.exchange),
        ])
        return OrderResult(orderNo: str(data["ordr_no"]).trimmingCharacters(in: .whitespaces), time: MarketClock.timeString())
    }

    /// SSAM1806 취소주문 (잔량 전부)
    public func cancel(_ item: DailyOrderItem) async throws -> OrderResult {
        let data = try await call(tr: "SSAM1806", body: [
            "is_cd": item.code,
            "ordr_q": "",
            "crct_clsf": "2",
            "orgn_ordr_no": item.orderNo,
        ])
        return OrderResult(orderNo: str(data["ordr_no"]).trimmingCharacters(in: .whitespaces), time: MarketClock.timeString())
    }

    /// SSQM2341 체결/미체결 조회 (ccls_clsf 0:전체 1:체결 2:미체결, 당일)
    public func dailyOrders(_ filter: CcldFilter) async throws -> [DailyOrderItem] {
        let clsf: String
        switch filter {
        case .all: clsf = "0"
        case .executed: clsf = "1"
        case .pending: clsf = "2"
        }
        let rows = try await callPaged(tr: "SSQM2341", body: ["ccls_clsf": clsf, "ordr_dt": MarketClock.todayString()], rowsKey: "Record1")
        return Self.makeOrders(rows, filter: filter)
    }

    static func makeOrders(_ rows: [[String: Any]], filter: CcldFilter) -> [DailyOrderItem] {
        rows.compactMap { o in
            let execQty = BrokerNumber.int(o["tl_ccls_q"])
            let remain = BrokerNumber.int(o["nccls_q"])
            switch filter {
            case .all: break
            case .executed: guard execQty > 0 else { return nil }
            case .pending: guard remain > 0 else { return nil }
            }
            let avg = BrokerNumber.double(o["ccls_uprc"])
            return DailyOrderItem(
                orderNo: str(o["ordr_no"]).trimmingCharacters(in: .whitespaces),
                code: str(o["stnd_is_no"]).trimmingCharacters(in: .whitespaces).removingPrefix("A"),
                nameKr: str(o["hngl_shrt_nm"]).trimmingCharacters(in: .whitespaces),
                side: str(o["trd_dl_ccd_nm"]).contains("매수") ? .buy : .sell,
                orderQty: BrokerNumber.int(o["ordr_q"]),
                orderPrice: BrokerNumber.int(o["ordr_uprc"]),
                execQty: execQty,
                execAvgPrice: avg,
                execAmount: Int((avg * Double(execQty)).rounded()),
                remainQty: remain,
                orderTime: str(o["ordr_tm"]).trimmingCharacters(in: .whitespaces),
                status: remain > 0 ? (execQty > 0 ? "일부체결" : "미체결") : "체결",
                orderType: "",
                exchange: KbExchange.fromCode(str(o["sor_ordr_ccd"]).trimmingCharacters(in: .whitespaces)),
                canceled: false
            )
        }
    }

    /// KB 는 주문가능 조회를 쓰지 않는다.
    public func buyableInfo(code: String, price: Int) async throws -> BuyableInfo? { nil }
}

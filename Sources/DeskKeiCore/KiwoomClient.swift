import Foundation

/// 키움증권 REST API 클라이언트 (https://api.kiwoom.com). 인증과 잔고 조회를 지원한다.
public final class KiwoomClient: BrokerClient {
    public static let baseURL = URL(string: "https://api.kiwoom.com")!
    /// 토큰이 무효할 때 서버가 주는 return_code
    static let tokenErrorCode = 3
    /// 이어받기(cont-yn) 최대 횟수
    static let maxPages = 5

    let account: BrokerAccount
    private let session: URLSession
    private let tokens: BrokerTokenCache

    public init(account: BrokerAccount, session: URLSession = .shared, tokenStore: JSONStore = JSONStore("tokens.json")) {
        self.account = account
        self.session = session
        self.tokens = BrokerTokenCache(store: tokenStore, key: "kiwoom:" + String(account.appKey.prefix(12)))
    }

    // MARK: 인증

    public func verify() async throws { _ = try await accessToken() }

    func accessToken() async throws -> String {
        guard account.hasCredentials else { throw KisError.notConfigured }
        if let t = tokens.load() { return t }
        let (json, _) = try await BrokerHTTP.post(session: session, url: Self.baseURL.appendingPathComponent("oauth2/token"), headers: [:], body: [
            "grant_type": "client_credentials",
            "appkey": account.appKey,
            "secretkey": account.appSecret,
        ])
        guard int(json["return_code"]) == 0, let token = json["token"] as? String, !token.isEmpty else {
            let msg = str(json["return_msg"])
            throw KisError(msg.isEmpty ? "키움 토큰 발급 실패" : "키움 토큰 오류: \(msg)")
        }
        tokens.save(token, expiresAt: Self.expiry(str(json["expires_dt"])))
        return token
    }

    /// 만료 시각 "yyyyMMddHHmmss" (KST). 읽지 못하면 24시간 뒤로 본다.
    static func expiry(_ text: String, now: Date = Date()) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: text) ?? now.addingTimeInterval(86_400)
    }

    // MARK: 호출

    /// 한 번 호출한다. 토큰이 무효하면 버리고 새로 받아 한 번만 다시 시도한다.
    /// 응답 본문과 이어받기 정보(cont-yn / next-key)를 돌려준다.
    func call(path: String, apiId: String, body: [String: String], nextKey: String = "") async throws -> (json: [String: Any], next: String?) {
        func attempt() async throws -> (json: [String: Any], next: String?) {
            let token = try await accessToken()
            let (json, http) = try await BrokerHTTP.post(session: session, url: Self.baseURL.appendingPathComponent(path), headers: [
                "authorization": "Bearer \(token)",
                "api-id": apiId,
                "cont-yn": nextKey.isEmpty ? "N" : "Y",
                "next-key": nextKey,
            ], body: body)
            let code = int(json["return_code"])
            if code == Self.tokenErrorCode { throw TokenRejected() }
            guard (200..<300).contains(http.statusCode), code == 0 else {
                let msg = str(json["return_msg"])
                throw KisError(msg.isEmpty ? "키움 요청 실패: HTTP \(http.statusCode)" : "키움 오류: \(msg)")
            }
            let more = http.value(forHTTPHeaderField: "cont-yn") == "Y"
            let key = http.value(forHTTPHeaderField: "next-key") ?? ""
            return (json, more && !key.isEmpty ? key : nil)
        }
        do { return try await attempt() }
        catch is TokenRejected {
            tokens.clear()
            do { return try await attempt() }
            catch is TokenRejected { throw KisError("키움 토큰이 유효하지 않습니다. 앱 키와 시크릿 키를 확인해 주세요.") }
        }
    }

    private struct TokenRejected: Error {}

    // MARK: 잔고

    public func balance() async throws -> (assets: [AssetItem], summary: AccountSummary) {
        // kt00018 계좌평가잔고내역: 요약은 첫 페이지 최상위, 종목은 acnt_evlt_remn_indv_tot
        let body = [
            "acnt_no": account.accountNo,
            "acnt_pw": account.password,
            "qry_tp": "0",
            "dmst_stex_tp": "KRX",
            "inqr_tp_code": "0",
            "hist_dt": "",
            "stk_cd": "",
            "etf_tp_code": "0",
            "blnc_tp_code": "0",
            "ccld_tp_code": "0",
            "ord_gb_code": "0",
            "prdt_cd": "0",
            "inqr_cond_tp_code": "0",
            "inqr_sort_tp_code": "0",
        ]
        var first: [String: Any] = [:]
        var rows: [[String: Any]] = []
        var next = ""
        for page in 0..<Self.maxPages {
            let r = try await call(path: "api/dostk/acnt", apiId: "kt00018", body: body, nextKey: next)
            if page == 0 { first = r.json }
            rows += (r.json["acnt_evlt_remn_indv_tot"] as? [[String: Any]]) ?? []
            guard let key = r.next, key != next else { break }
            next = key
        }

        // kt00001 예수금상세현황
        let deposit = try await call(path: "api/dostk/acnt", apiId: "kt00001", body: [
            "acnt_no": account.accountNo,
            "acnt_prdt_cd": "01",
            "base_dt": "",
            "qry_tp": "0",
        ]).json
        return Self.makeBalance(summary: first, rows: rows, deposit: deposit)
    }

    /// 응답 JSON 을 앱 모델로 바꾼다. 가격은 부호를 떼고 손익만 부호를 유지한다.
    static func makeBalance(summary s: [String: Any], rows: [[String: Any]], deposit d: [String: Any]) -> (assets: [AssetItem], summary: AccountSummary) {
        var assets: [AssetItem] = []
        for r in rows {
            let qty = BrokerNumber.int(r["rmnd_qty"])
            guard qty > 0 else { continue }
            let price = abs(BrokerNumber.int(r["cur_prc"]))
            let prev = abs(BrokerNumber.int(r["pred_close_pric"]))
            let change = prev > 0 && price > 0 ? price - prev : 0
            let avg = abs(BrokerNumber.double(r["pur_pric"]))
            let purchase = BrokerNumber.int(r["pur_amt"])
            assets.append(AssetItem(
                code: str(r["stk_cd"]).trimmingCharacters(in: .whitespaces).removingPrefix("A"),
                nameKr: str(r["stk_nm"]).trimmingCharacters(in: .whitespaces),
                holdingQty: qty,
                purchaseAvgPrice: avg,
                purchaseAmount: purchase != 0 ? purchase : Int((avg * Double(qty)).rounded()),
                currentPrice: price,
                priceChange: change,
                priceChangeRate: prev > 0 ? Double(change) / Double(prev) * 100 : 0,
                evaluationAmount: abs(BrokerNumber.int(r["evlt_amt"])),
                profitLossAmount: BrokerNumber.int(r["evltv_prft"]),
                profitLossRate: BrokerNumber.double(r["prft_rt"])
            ))
        }

        var summary = AccountSummary()
        summary.stockEvaluationAmount = BrokerNumber.int(s["tot_evlt_amt"])
        summary.totalEvaluationAmount = BrokerNumber.int(s["prsm_dpst_aset_amt"])
        summary.netAssetAmount = summary.totalEvaluationAmount
        summary.purchaseAmountTotal = BrokerNumber.int(s["tot_pur_amt"])
        summary.profitLossTotal = BrokerNumber.int(s["tot_evlt_pl"])
        // 예수금(D+2): d2_entra 가 0 이면 100stk_ord_alow_amt 로 대신한다
        let d2 = BrokerNumber.int(d["d2_entra"])
        summary.depositAmount = d2 != 0 ? d2 : BrokerNumber.int(d["100stk_ord_alow_amt"])
        return (assets, summary)
    }
}

extension String {
    func removingPrefix(_ prefix: String) -> String { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self }
}

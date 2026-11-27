import Foundation

/// KB증권 Open API 클라이언트 (https://developer.kbsec.com:32484). 인증과 잔고 조회를 지원한다.
/// 모든 TR 을 `api/v1/<tr코드 소문자>` 로 POST 하고 요청·응답이 dataHeader / dataBody 로 감싸진다.
public final class KbClient: BrokerClient {
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

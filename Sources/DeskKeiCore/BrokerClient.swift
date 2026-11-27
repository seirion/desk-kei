import Foundation

/// 증권사별 클라이언트가 공통으로 제공하는 기능. 지금은 연결 확인과 잔고(자산) 조회다.
/// 시세·주문·선물옵션은 KIS(`KisClient`)만 지원한다.
public protocol BrokerClient {
    /// 인증(토큰 발급)까지 되는지 확인한다. 실패하면 이유를 담아 던진다.
    func verify() async throws
    /// 보유 종목과 계좌 요약
    func balance() async throws -> (assets: [AssetItem], summary: AccountSummary)
}

extension KisClient: BrokerClient {
    public func verify() async throws { _ = try await accessToken() }
}

public enum BrokerClients {
    /// 계정의 증권사에 맞는 클라이언트. 인증 정보가 비어 있으면 nil.
    public static func make(_ account: BrokerAccount, session: URLSession = .shared,
                            tokenStore: JSONStore = JSONStore("tokens.json")) -> BrokerClient? {
        guard account.hasCredentials else { return nil }
        switch account.broker {
        case .kis: return KisClient(account: account, session: session, tokenStore: tokenStore)
        case .kiwoom: return KiwoomClient(account: account, session: session, tokenStore: tokenStore)
        case .kb: return KbClient(account: account, session: session, tokenStore: tokenStore)
        }
    }
}

// MARK: - 키움·KB 공통

/// 키움·KB 응답의 숫자 문자열 변환. 앞이 0 이나 공백으로 채워져 있고 콤마·부호가 붙을 수 있다.
enum BrokerNumber {
    static func double(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        let s = str(v).replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return Double(s) ?? 0
    }

    static func int(_ v: Any?) -> Int { Int(double(v).rounded()) }
}

/// 토큰 캐시. KIS 와 같은 파일(tokens.json)을 쓰되 증권사 접두사로 키를 나눈다.
struct BrokerTokenCache {
    let store: JSONStore
    let key: String

    func load(now: Date = Date()) -> String? {
        guard let t = store.load([String: CachedToken].self)?[key], t.expiresAt > now else { return nil }
        return t.accessToken
    }

    func save(_ token: String, expiresAt: Date) {
        var cache = store.load([String: CachedToken].self) ?? [:]
        cache[key] = CachedToken(accessToken: token, expiresAt: expiresAt.addingTimeInterval(-60))
        store.save(cache)
    }

    func clear() {
        var cache = store.load([String: CachedToken].self) ?? [:]
        guard cache.removeValue(forKey: key) != nil else { return }
        store.save(cache)
    }
}

enum BrokerHTTP {
    /// JSON 본문을 POST 하고 (JSON 객체, 응답) 을 돌려준다. 해석할 수 없는 본문은 빈 객체로 둔다.
    static func post(session: URLSession, url: URL, headers: [String: String], body: Any) async throws -> (json: [String: Any], http: HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw KisError("응답을 해석할 수 없습니다.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json, http)
    }
}

import Foundation

/// 주식선물옵션 종류
public enum FuturesKind: String, Codable, CaseIterable, Identifiable {
    case future, call, put

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .future: return "선물"
        case .call: return "콜옵션"
        case .put: return "풋옵션"
        }
    }
    public var isOption: Bool { self != .future }
    /// 시세·호가 조회의 FID_COND_MRKT_DIV_CODE (JF: 주식선물, JO: 주식옵션)
    var marketDivision: String { isOption ? "JO" : "JF" }
}

/// 주식선물옵션 종목 하나 (선물 1개 월물 또는 옵션 1개 행사가)
public struct FuturesInstrument: Codable, Equatable, Hashable, Identifiable {
    /// 단축코드. 선물 6자리, 옵션 9자리
    public var code: String
    /// 마스터의 종목명 (공백으로 정렬된 원문)
    public var name: String
    public var kind: FuturesKind
    public var underlyingCode: String
    public var underlyingName: String
    /// 만기 월 yyyyMM
    public var expiry: String
    /// 행사가 (선물은 0)
    public var strike: Int
    /// 계약 승수. 종목명 끝의 "(  10)" 에서 읽으며, 없으면 0 (알 수 없음)
    public var multiplier: Int

    public var id: String { code }

    public init(code: String, name: String, kind: FuturesKind, underlyingCode: String, underlyingName: String,
                expiry: String, strike: Int, multiplier: Int) {
        self.code = code
        self.name = name
        self.kind = kind
        self.underlyingCode = underlyingCode
        self.underlyingName = underlyingName
        self.expiry = expiry
        self.strike = strike
        self.multiplier = multiplier
    }

    /// "삼성전자 선물 26.12", "삼성전자 콜 26.11 190,000"
    public var title: String {
        let month = expiry.count == 6 ? "\(expiry.dropFirst(2).prefix(2)).\(expiry.suffix(2))" : expiry
        switch kind {
        case .future: return "\(underlyingName) 선물 \(month)"
        case .call: return "\(underlyingName) 콜 \(month) \(fmt(strike))"
        case .put: return "\(underlyingName) 풋 \(month) \(fmt(strike))"
        }
    }

    /// 만기 월 표시: "2026.12"
    public static func expiryLabel(_ expiry: String) -> String {
        expiry.count == 6 ? "\(expiry.prefix(4)).\(expiry.suffix(2))" : expiry
    }
}

/// 종목 검색·선택용 색인
public struct FuturesCatalog {
    public let instruments: [FuturesInstrument]
    public let byCode: [String: FuturesInstrument]
    private let byUnderlying: [String: [FuturesInstrument]]
    /// (기초자산 코드, 이름) — 이름순
    public let underlyings: [(code: String, name: String)]

    public init(instruments: [FuturesInstrument]) {
        self.instruments = instruments
        byCode = Dictionary(instruments.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        byUnderlying = Dictionary(grouping: instruments, by: \.underlyingCode)
        var names: [String: String] = [:]
        for i in instruments { names[i.underlyingCode] = i.underlyingName }
        underlyings = names.map { (code: $0.key, name: $0.value) }.sorted { $0.name == $1.name ? $0.code < $1.code : $0.name < $1.name }
    }

    public var isEmpty: Bool { instruments.isEmpty }

    public func instruments(underlying: String) -> [FuturesInstrument] { byUnderlying[underlying] ?? [] }

    /// 그 기초자산·종류에 있는 만기 월 (빠른 순)
    public func expiries(underlying: String, kind: FuturesKind) -> [String] {
        Array(Set(instruments(underlying: underlying).filter { $0.kind == kind }.map(\.expiry))).sorted()
    }

    /// 그 기초자산·옵션 종류·만기의 행사가 (낮은 순)
    public func strikes(underlying: String, kind: FuturesKind, expiry: String) -> [Int] {
        Array(Set(instruments(underlying: underlying).filter { $0.kind == kind && $0.expiry == expiry }.map(\.strike))).sorted()
    }

    public func instrument(underlying: String, kind: FuturesKind, expiry: String, strike: Int) -> FuturesInstrument? {
        instruments(underlying: underlying).first { $0.kind == kind && $0.expiry == expiry && $0.strike == strike }
    }

    /// 기초자산 이름/코드 부분 일치 (이름이 검색어로 시작하는 것을 먼저). 단축코드가 검색어로 시작하는 종목은 뒤에 붙인다.
    public func search(_ query: String, limit: Int) -> [(key: String, name: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var prefix: [(code: String, name: String)] = []
        var rest: [(code: String, name: String)] = []
        for u in underlyings {
            let name = u.name.lowercased()
            if name.hasPrefix(q) || u.code.hasPrefix(q) { prefix.append(u) }
            else if name.contains(q) || u.code.contains(q) { rest.append(u) }
        }
        var results = (prefix + rest).prefix(limit).map { (key: Self.underlyingKey($0.code), name: $0.name) }
        if q.count >= 3, results.count < limit {
            let upper = query.trimmingCharacters(in: .whitespaces).uppercased()
            let codes = instruments.filter { $0.code.hasPrefix(upper) }.prefix(limit - results.count)
            results += codes.map { (key: $0.code, name: $0.title) }
        }
        return results
    }

    /// 검색 결과 중 기초자산을 가리키는 키
    public static func underlyingKey(_ code: String) -> String { "u:\(code)" }
    public static func underlyingCode(fromKey key: String) -> String? {
        key.hasPrefix("u:") ? String(key.dropFirst(2)) : nil
    }
}

/// 주식선물옵션 마스터 파일(fo_stk_code_mts) 다운로드·파싱·캐시.
///
/// - URL: https://new.real.download.dws.co.kr/common/master/fo_stk_code_mts.mst.zip
/// - 인코딩 CP949, 한 줄이 `|` 로 나뉜 9개 필드:
///   상품종류 | 단축코드 | 표준코드 | 종목명 | ATM구분 | 행사가 | 월물순번 | 기초자산 코드 | 기초자산명
/// - 상품종류: 1·3·7 선물(코스피·코스닥·ETF), 2·4·8 스프레드, 5 콜옵션, 6 풋옵션 — 스프레드는 쓰지 않는다.
public enum FuturesMaster {
    static let fileName = "fo_stk_code_mts"

    struct Cache: Codable {
        var timestamp: Date
        var data: [FuturesInstrument]
    }

    /// 캐시 우선으로 불러오고, 마지막 갱신 시각 이후에 만든 캐시가 아니면 새로 받는다.
    /// `force` 면 캐시를 무시하고 새로 받으며, 실패해도 오래된 캐시로 대신하지 않고 오류를 던진다.
    public static func load(store: JSONStore = JSONStore("fo_master.json"), now: Date = Date(),
                            force: Bool = false) async throws -> [FuturesInstrument] {
        let cache = store.load(Cache.self)
        if !force, let cache, StockMaster.isCacheValid(cache.timestamp, now: now) { return active(cache.data, now: now) }
        do {
            let all = try await download()
            store.save(Cache(timestamp: now, data: all))
            return active(all, now: now)
        } catch {
            if !force, let cache { return active(cache.data, now: now) }
            throw error
        }
    }

    public static func cachedAt(store: JSONStore = JSONStore("fo_master.json")) -> Date? {
        store.load(Cache.self)?.timestamp
    }

    /// 만기 월이 이번 달 이전인 종목은 뺀다.
    static func active(_ items: [FuturesInstrument], now: Date) -> [FuturesInstrument] {
        let today = MarketClock.todayString(now)
        let month = String(today.prefix(6))
        return items.filter { $0.expiry >= month }
    }

    static func download() async throws -> [FuturesInstrument] {
        let url = URL(string: "\(StockMaster.baseURL)/\(fileName).mst.zip")!
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw KisError("선물옵션 마스터 파일 다운로드 실패: \(http.statusCode)")
        }
        return parse(mst: try StockMaster.unzipFirst(data))
    }

    static func parse(mst: Data) -> [FuturesInstrument] {
        let text = StockMaster.decodeCP949(mst)
        var result: [FuturesInstrument] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 9 else { continue }
            let kind: FuturesKind
            switch f[0] {
            case "1", "3", "7": kind = .future
            case "5": kind = .call
            case "6": kind = .put
            default: continue
            }
            let name = f[3]
            guard !f[1].isEmpty, let expiry = expiry(in: name) else { continue }
            result.append(FuturesInstrument(
                code: f[1], name: name, kind: kind,
                underlyingCode: f[7], underlyingName: f[8],
                expiry: expiry,
                strike: kind.isOption ? (Int(f[5]) ?? Int(Double(f[5]) ?? 0)) : 0,
                multiplier: multiplier(in: name)
            ))
        }
        return result
    }

    /// 종목명 "삼성전자   F 202611 (  10)" 에서 만기 월(202611)
    static func expiry(in name: String) -> String? {
        guard let r = name.range(of: #"(?<=[FCP]\s)\s*\d{6}"#, options: .regularExpression) else { return nil }
        return name[r].trimmingCharacters(in: .whitespaces)
    }

    /// 종목명 끝의 "(  10)" → 10, 없으면 0. 조정 종목은 뒤에 `*` 가 붙는다.
    static func multiplier(in name: String) -> Int {
        guard let r = name.range(of: #"\(\s*\d+\s*\)\s*\*?\s*$"#, options: .regularExpression) else { return 0 }
        return Int(name[r].filter(\.isNumber)) ?? 0
    }
}

/// 호가 목록에서 호가 단위를 추정한다. 가격들의 최대공약수 — 호가 단위의 배수 격자 위에 있으므로
/// 실제 단위이거나 그 배수다. 호가가 없으면 1.
public func inferTick(_ book: OrderBook?) -> Int {
    func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    let prices = ((book?.asks ?? []) + (book?.bids ?? [])).map(\.price).filter { $0 > 0 }
    guard let first = prices.first else { return 1 }
    return max(1, prices.dropFirst().reduce(first, gcd))
}

/// 호가 단위 격자에 맞춰 한 칸 위/아래로. 아래로는 한 단위 미만으로 내려가지 않는다.
public func stepPrice(_ price: Int, up: Bool, tick: Int) -> Int {
    let t = max(1, tick)
    return up ? (price / t + 1) * t : max(t, ((price - 1) / t) * t)
}

import Foundation

/// ~/Library/Application Support/DeskKei 아래에 JSON 으로 저장한다.
/// 계정 정보가 들어 있는 파일은 소유자만 읽고 쓸 수 있게(0600) 만든다.
public final class JSONStore {
    public static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeskKei", isDirectory: true)
    }()

    private let url: URL

    public var filename: String { url.lastPathComponent }

    public init(_ filename: String, directory: URL = JSONStore.directory) {
        self.url = directory.appendingPathComponent(filename)
    }

    public func load<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func save<T: Encodable>(_ value: T) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(value)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("DeskKei: failed to save \(url.lastPathComponent): \(error)")
        }
    }
}

/// 계정 목록 + 현재 사용 중인 계정
public struct AccountsFile: Codable {
    public var accounts: [BrokerAccount] = []
    public var active: String = ""
    /// 시세를 받는 데 쓸 KIS 계정 이름. 사용 중인 계정이 KIS 가 아닐 때만 쓰며, 비어 있으면 첫 KIS 계정을 쓴다.
    public var marketAccount: String = ""
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([BrokerAccount].self, forKey: .accounts) ?? []
        active = try c.decodeIfPresent(String.self, forKey: .active) ?? ""
        marketAccount = try c.decodeIfPresent(String.self, forKey: .marketAccount) ?? ""
    }
}

/// 관심종목 10개 그룹 + 그룹 이름
public struct WatchlistFile: Codable, Equatable {
    public static let groupCount = 10
    public var groups: [[String]] = Array(repeating: [], count: WatchlistFile.groupCount)
    public var names: [String] = Array(repeating: "", count: WatchlistFile.groupCount)
    public init() {}

    /// 저장된 값이 열 개 미만이어도 항상 10개 그룹을 보장한다.
    public mutating func normalize() {
        while groups.count < Self.groupCount { groups.append([]) }
        while names.count < Self.groupCount { names.append("") }
        if groups.count > Self.groupCount { groups = Array(groups.prefix(Self.groupCount)) }
        if names.count > Self.groupCount { names = Array(names.prefix(Self.groupCount)) }
    }
}

public struct RecentStock: Codable, Equatable {
    public var code: String
    public var name: String
    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

/// 주문 화면 상태 (마지막 종목, 최근 종목)
public struct OrderPrefsFile: Codable {
    public static let recentMax = 20
    public var last = RecentStock(code: "005930", name: "삼성전자")
    public var recent: [RecentStock] = []
    public init() {}

    public mutating func touch(code: String, name: String) {
        last = RecentStock(code: code, name: name)
        recent.removeAll { $0.code == code }
        recent.insert(last, at: 0)
        if recent.count > Self.recentMax { recent = Array(recent.prefix(Self.recentMax)) }
    }

    public mutating func removeRecent(code: String) {
        recent.removeAll { $0.code == code }
    }
}

/// 선물/옵션 화면 상태 (마지막 종목, 최근 종목). 코드는 선물옵션 단축코드.
public struct FuturesPrefsFile: Codable {
    public static let recentMax = 20
    public var last: RecentStock?
    public var recent: [RecentStock] = []
    public init() {}

    public mutating func touch(code: String, name: String) {
        let item = RecentStock(code: code, name: name)
        last = item
        recent.removeAll { $0.code == code }
        recent.insert(item, at: 0)
        if recent.count > Self.recentMax { recent = Array(recent.prefix(Self.recentMax)) }
    }

    public mutating func removeRecent(code: String) {
        recent.removeAll { $0.code == code }
    }
}

/// 선물/옵션 즐겨찾기 (순서 유지). 코드는 선물옵션 단축코드, 이름은 담을 때의 종목 표시명.
public struct FuturesFavoritesFile: Codable, Equatable {
    public var items: [RecentStock] = []
    public init() {}

    public func contains(_ code: String) -> Bool { items.contains { $0.code == code } }

    /// 있으면 빼고 없으면 맨 뒤에 담는다. 담았으면 true.
    @discardableResult
    public mutating func toggle(code: String, name: String) -> Bool {
        if let idx = items.firstIndex(where: { $0.code == code }) {
            items.remove(at: idx)
            return false
        }
        items.append(RecentStock(code: code, name: name))
        return true
    }

    /// 없으면 맨 뒤에 담는다. 새로 담았으면 true, 이미 있으면 false.
    @discardableResult
    public mutating func add(code: String, name: String) -> Bool {
        guard !contains(code) else { return false }
        items.append(RecentStock(code: code, name: name))
        return true
    }

    /// 주어진 코드 순서로 바꾼다. 목록에 없는 코드는 무시하고, 빠진 항목은 지운 것으로 본다.
    public mutating func reorder(_ codes: [String]) {
        let byCode = Dictionary(items.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        items = codes.compactMap { byCode[$0] }
    }
}

/// 차트 설정. indicators 가 nil 이면 저장된 적이 없는 것으로 보고 기본 지표(MA, VOL)를 쓴다.
public struct ChartPrefsFile: Codable, Equatable {
    public var indicators: [String]?
    public init(indicators: [String]? = nil) { self.indicators = indicators }
}

public struct AppStateFile: Codable {
    public var lastTab: String = "watchlist"
    public var activeGroup: Int = 0
    /// system / light / dark
    public var appearance: String = "system"
    /// 신규 주문 전에 확인 팝업을 띄울지
    public var confirmOrders: Bool = true
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastTab = try c.decodeIfPresent(String.self, forKey: .lastTab) ?? lastTab
        activeGroup = try c.decodeIfPresent(Int.self, forKey: .activeGroup) ?? activeGroup
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        confirmOrders = try c.decodeIfPresent(Bool.self, forKey: .confirmOrders) ?? confirmOrders
    }
}

struct CachedToken: Codable {
    var accessToken: String
    var expiresAt: Date
}

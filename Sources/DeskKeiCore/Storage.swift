import Foundation

/// ~/Library/Application Support/DeskKei 아래에 JSON 으로 저장한다.
/// 계정 정보가 들어 있는 파일은 소유자만 읽고 쓸 수 있게(0600) 만든다.
public final class JSONStore {
    public static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeskKei", isDirectory: true)
    }()

    private let url: URL

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
    public var accounts: [KisAccount] = []
    public var active: String = ""
    public init() {}
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
}

public struct AppStateFile: Codable {
    public var lastTab: String = "watchlist"
    public var activeGroup: Int = 0
    public init() {}
}

struct CachedToken: Codable {
    var accessToken: String
    var expiresAt: Date
}

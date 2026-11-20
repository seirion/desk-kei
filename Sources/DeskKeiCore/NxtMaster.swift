import Foundation

/// NXT 거래 종목 목록(KOSPI/KOSDAQ). 이 목록에 없는 종목(대부분 ETF)은 프리장·애프터에 거래되지 않는다.
///
/// - URL: https://new.real.download.dws.co.kr/common/master/nxt_{kospi|kosdaq}_code.mst.zip
/// - 종목 마스터와 같은 형식(CP949 고정폭)이며 앞 9자가 종목코드다.
public enum NxtMaster {
    struct Cache: Codable {
        var timestamp: Date
        var codes: [String]
    }

    /// 캐시 우선으로 불러오고, 종목 마스터와 같은 갱신 시각 규칙으로 새로 받는다.
    /// `force` 면 캐시를 무시하고 새로 받으며, 실패해도 오래된 캐시로 대신하지 않고 오류를 던진다.
    public static func load(store: JSONStore = JSONStore("nxt_master.json"), now: Date = Date(),
                            force: Bool = false) async throws -> Set<String> {
        let cache = store.load(Cache.self)
        if !force, let cache, StockMaster.isCacheValid(cache.timestamp, now: now) { return Set(cache.codes) }
        do {
            async let kospi = download("nxt_kospi_code")
            async let kosdaq = download("nxt_kosdaq_code")
            let codes = try await kospi.union(try await kosdaq)
            // 비어 있으면 파일이 잘못된 것으로 보고 모든 종목을 거래 불가로 표시하지 않도록 한다.
            guard !codes.isEmpty else { throw KisError("NXT 종목 목록이 비어 있습니다.") }
            store.save(Cache(timestamp: now, codes: codes.sorted()))
            return codes
        } catch {
            if !force, let cache { return Set(cache.codes) }
            throw error
        }
    }

    public static func cachedAt(store: JSONStore = JSONStore("nxt_master.json")) -> Date? {
        store.load(Cache.self)?.timestamp
    }

    static func download(_ name: String) async throws -> Set<String> {
        let url = URL(string: "\(StockMaster.baseURL)/\(name).mst.zip")!
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw KisError("NXT 종목 목록 다운로드 실패: \(http.statusCode)")
        }
        return parse(mst: try StockMaster.unzipFirst(data))
    }

    static func parse(mst: Data) -> Set<String> {
        var codes = Set<String>()
        for line in StockMaster.decodeCP949(mst).split(whereSeparator: \.isNewline) {
            let u = Array(line.utf16)
            guard u.count >= 9 else { continue }
            let code = String(decoding: u[0..<9], as: UTF16.self).trimmingCharacters(in: .whitespaces)
            if !code.isEmpty { codes.insert(code) }
        }
        return codes
    }
}

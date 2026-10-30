import Foundation
import Compression

/// KIS 종목 마스터 파일(KOSPI/KOSDAQ) 다운로드·파싱·캐시.
///
/// - URL: https://new.real.download.dws.co.kr/common/master/{exchange}_code.mst.zip
/// - 인코딩: CP949
/// - 고정폭: code = [0,9), nameKr = [21, len-ATTR_LEN), 나머지는 속성 영역
public enum StockMaster {
    static let baseURL = "https://new.real.download.dws.co.kr/common/master"
    /// 마스터 파일이 갱신되는 시각 (HHMM)
    static let uploadTimes = [600, 655, 735, 755, 845, 946, 1055, 1710, 1730, 1755, 1810, 1830, 1855]

    struct Cache: Codable {
        var timestamp: Date
        var data: [String: StockInfo]
    }

    enum Exchange {
        case kospi, kosdaq
        var name: String { self == .kospi ? "kospi" : "kosdaq" }
        var attrLen: Int { self == .kospi ? 227 : 221 }
        /// 속성 영역 안에서 기준가(9자) / 거래정지 / 관리종목 위치
        var prevAt: Int { self == .kospi ? 41 : 36 }
        var haltAt: Int { self == .kospi ? 60 : 55 }
        var designatedAt: Int { self == .kospi ? 62 : 57 }
    }

    /// 캐시 우선으로 불러오고, 마지막 갱신 시각 이후에 만든 캐시가 아니면 새로 받는다.
    /// `force` 면 캐시를 무시하고 새로 받으며, 실패해도 오래된 캐시로 대신하지 않고 오류를 던진다.
    public static func load(store: JSONStore = JSONStore("master.json"), now: Date = Date(),
                            force: Bool = false) async throws -> [String: StockInfo] {
        let cache = store.load(Cache.self)
        if !force, let cache, isCacheValid(cache.timestamp, now: now) { return cache.data }
        do {
            async let kospi = download(.kospi)
            async let kosdaq = download(.kosdaq)
            let merged = try await kospi.merging(try await kosdaq) { a, _ in a }
            store.save(Cache(timestamp: now, data: merged))
            return merged
        } catch {
            if !force, let cache { return cache.data }
            throw error
        }
    }

    /// 캐시를 만든(내려받은) 시각
    public static func cachedAt(store: JSONStore = JSONStore("master.json")) -> Date? {
        store.load(Cache.self)?.timestamp
    }

    /// 현재 시각 기준 가장 최근 갱신 시각 이후에 만들어진 캐시인지
    static func isCacheValid(_ cached: Date, now: Date) -> Bool {
        let cal = MarketClock.calendar
        let hhmm = MarketClock.minutes(now) / 60 * 100 + MarketClock.minutes(now) % 60
        var validFrom: Date
        if let last = uploadTimes.last(where: { $0 <= hhmm }) {
            validFrom = cal.date(bySettingHour: last / 100, minute: last % 100, second: 0, of: now)!
        } else {
            let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
            validFrom = cal.date(bySettingHour: 18, minute: 55, second: 0, of: yesterday)!
        }
        return cached >= validFrom
    }

    static func download(_ exchange: Exchange) async throws -> [String: StockInfo] {
        let url = URL(string: "\(baseURL)/\(exchange.name)_code.mst.zip")!
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw KisError("마스터 파일 다운로드 실패: \(http.statusCode)")
        }
        return parse(mst: try unzipFirst(data), exchange: exchange)
    }

    static func parse(mst: Data, exchange: Exchange) -> [String: StockInfo] {
        let text = decodeCP949(mst)
        var result: [String: StockInfo] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let u = Array(line.utf16)
            guard u.count >= 21 + exchange.attrLen else { continue }
            let code = String(decoding: u[0..<9], as: UTF16.self).trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else { continue }
            let attrStart = u.count - exchange.attrLen
            let name = String(decoding: u[21..<attrStart], as: UTF16.self).trimmingCharacters(in: .whitespaces)
            let attrs = Array(u[attrStart...])
            func char(_ i: Int) -> UInt16 { attrs[i] }
            let prev = String(decoding: attrs[exchange.prevAt..<exchange.prevAt + 9], as: UTF16.self).trimmingCharacters(in: .whitespaces)
            let y = UInt16(UInt8(ascii: "Y"))
            result[code] = StockInfo(
                nameKr: name,
                prevPrice: Int(prev) ?? 0,
                halt: char(exchange.haltAt) == y,
                designated: char(exchange.designatedAt) == y
            )
        }
        return result
    }

    static func decodeCP949(_ data: Data) -> String {
        let cf = CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        return String(data: data, encoding: enc) ?? String(decoding: data, as: UTF8.self)
    }

    /// ZIP 의 첫 번째 파일을 꺼낸다 (store / deflate 만 지원)
    static func unzipFirst(_ zip: Data) throws -> Data {
        let b = [UInt8](zip)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count > 30, u32(0) == 0x04034b50 else { throw KisError("ZIP 파일이 아닙니다.") }
        let method = u16(8)
        let compSize = u32(18)
        let uncompSize = u32(22)
        let start = 30 + u16(26) + u16(28)
        guard start + compSize <= b.count else { throw KisError("ZIP 데이터가 손상되었습니다.") }
        let body = Data(b[start..<start + compSize])
        switch method {
        case 0:
            return body
        case 8:
            var out = Data(count: uncompSize)
            let n = out.withUnsafeMutableBytes { dst in
                body.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, uncompSize,
                                              src.bindMemory(to: UInt8.self).baseAddress!, compSize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard n == uncompSize else { throw KisError("ZIP 압축 해제 실패") }
            return out
        default:
            throw KisError("지원하지 않는 ZIP 방식: \(method)")
        }
    }
}

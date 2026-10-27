import Testing
import Foundation
import CommonCrypto
@testable import DeskKeiCore

@Suite struct MarketTests {
    @Test func tickSizes() {
        #expect(tickSize(1_999) == 1)
        #expect(tickSize(2_000) == 5)
        #expect(tickSize(19_999) == 10)
        #expect(tickSize(50_000) == 100)
        #expect(tickSize(499_999) == 500)
        #expect(tickSize(500_000) == 1_000)
    }

    @Test func stepNeverDropsBelowOne() {
        #expect(stepPrice(1, up: false) == 1)
        #expect(stepPrice(70_000, up: true) == 70_100)
        #expect(stepPrice(70_000, up: false) == 69_900)
    }

    @Test func sessions() {
        func kst(_ h: Int, _ m: Int) -> Date {
            var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 10; c.hour = h; c.minute = m
            return MarketClock.calendar.date(from: c)!
        }
        #expect(MarketClock.isNxtHour(kst(8, 30)))
        #expect(!MarketClock.isNxtHour(kst(9, 0)))
        #expect(MarketClock.isRegularHour(kst(9, 0)))
        #expect(!MarketClock.isRegularHour(kst(15, 30)))
        #expect(MarketClock.isNxtHour(kst(19, 59)))
        #expect(!MarketClock.isNxtHour(kst(20, 0)))
        #expect(MarketClock.todayString(kst(12, 0)) == "20260310")
        #expect(!MarketClock.isKrxAfterMarket(kst(15, 59)))
        #expect(MarketClock.isKrxAfterMarket(kst(16, 0)))
        #expect(MarketClock.isKrxAfterMarket(kst(19, 59)))
        #expect(!MarketClock.isKrxAfterMarket(kst(20, 0)))
        #expect(MarketClock.limitOrderDivision(kst(12, 0)) == "00")
        #expect(MarketClock.limitOrderDivision(kst(16, 0)) == "41")
    }

    @Test func formatting() {
        #expect(fmt(1_234_567) == "1,234,567")
        #expect(fmtSigned(5) == "+5")
        #expect(fmtSigned(-5) == "-5")
        #expect(formatChange(change: 1_000, sign: "2", rate: 1.234).text == "+1,000 (+1.23%)")
        #expect(formatChange(change: 500, sign: "5", rate: nil).text == "-500")
        #expect(formatChange(change: 0, sign: "3", rate: 0).direction == .flat)
        #expect(formatOrderTime("093015") == "09:30:15")
        #expect(formatVolume(1_500_000) == "1.5M")
    }
}

@Suite struct ModelTests {
    @Test func accountParts() {
        let a = KisAccount(name: "a", accountNo: "12345678-01", appKey: "k", appSecret: "s")
        #expect(a.accountParts.cano == "12345678")
        #expect(a.accountParts.product == "01")
        #expect(a.hasTradingAccount)
        #expect(!KisAccount(name: "b", appKey: "k", appSecret: "s").hasTradingAccount)
    }

    @Test func watchlistNormalizes() {
        var w = WatchlistFile()
        w.groups = [["005930"]]
        w.names = []
        w.normalize()
        #expect(w.groups.count == 10)
        #expect(w.names.count == 10)
        #expect(w.groups[0] == ["005930"])
    }

    @Test func recentStocksAreDeduplicatedAndCapped() {
        var p = OrderPrefsFile()
        for i in 0..<30 { p.touch(code: String(i), name: "n\(i)") }
        p.touch(code: "5", name: "n5")
        #expect(p.recent.count == 20)
        #expect(p.recent.first?.code == "5")
        #expect(p.recent.filter { $0.code == "5" }.count == 1)
    }

    @Test func dailyProfit() {
        let item = AssetItem(code: "1", nameKr: "n", holdingQty: 10, purchaseAvgPrice: 100, purchaseAmount: 1000,
                             currentPrice: 110, priceChange: 10, priceChangeRate: 10, evaluationAmount: 1100,
                             profitLossAmount: 100, profitLossRate: 10)
        #expect(item.dailyProfitLoss == 100)
        #expect(abs(item.dailyRate - 10) < 0.0001)
    }

    @Test func jsonStoreRoundTripWithOwnerOnlyPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONStore("a.json", directory: dir)
        var file = AccountsFile()
        file.accounts = [KisAccount(name: "x", appKey: "k", appSecret: "s")]
        store.save(file)
        #expect(store.load(AccountsFile.self)?.accounts.first?.name == "x")
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("a.json").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
}

@Suite struct RealtimeDecoderTests {
    /// H0STCNT0 필드 43개 중 앞쪽 일부만 채운 체결 메시지
    private func tradeMessage(sign: String, delta: String) -> String {
        var f = Array(repeating: "0", count: 20)
        f[0] = "005930"; f[2] = "70500"; f[3] = sign; f[4] = delta; f[5] = "1.45"
        f[7] = "70000"; f[8] = "71000"; f[9] = "69800"; f[13] = "1234567"
        return "0|H0STCNT0|001|" + f.joined(separator: "^")
    }

    @Test func parsesTrade() {
        var d = RealtimeDecoder()
        guard case .event(.trade(let t)) = d.decode(tradeMessage(sign: "5", delta: "500")) else {
            Issue.record("not a trade"); return
        }
        #expect(t.code == "005930")
        #expect(t.price == 70_500)
        #expect(t.sign == "5")
        #expect(t.change == 500)
        #expect(t.high == 71_000)
        #expect(t.volume == 1_234_567)
        #expect(!t.isNxt)
    }

    @Test func tradeFallsBackToDeltaSign() {
        var d = RealtimeDecoder()
        guard case .event(.trade(let t)) = d.decode(tradeMessage(sign: "x", delta: "-300")) else {
            Issue.record("not a trade"); return
        }
        #expect(t.sign == "5")
        #expect(t.change == 300)
    }

    @Test func parsesOrderBook() {
        var f = Array(repeating: "0", count: 50)
        f[0] = "005930"
        for i in 0..<10 {
            f[3 + i] = String(70_100 + i * 100); f[23 + i] = String(10 + i)
            f[13 + i] = String(70_000 - i * 100); f[33 + i] = String(20 + i)
        }
        var d = RealtimeDecoder()
        guard case .event(.orderBook(let b)) = d.decode("0|H0STASP0|001|" + f.joined(separator: "^")) else {
            Issue.record("not an order book"); return
        }
        #expect(b.asks[0] == OrderBookLevel(price: 70_100, qty: 10))
        #expect(b.bids[9] == OrderBookLevel(price: 69_100, qty: 29))
    }

    @Test func pingAndIgnoredMessages() {
        var d = RealtimeDecoder()
        #expect(d.decode("PINGPONG") == .ping("PINGPONG"))
        let json = #"{"header":{"tr_id":"PINGPONG","datetime":"20260310"}}"#
        #expect(d.decode(json) == .ping(json))
        #expect(d.decode("0|H0STCNT0|001") == .ignored)
    }

    @Test func decryptsExecutionNotice() {
        let key = "0123456789abcdef0123456789abcdef", iv = "abcdef9876543210"
        var d = RealtimeDecoder()
        _ = d.decode(#"{"header":{"tr_id":"H0STCNI0"},"body":{"rt_cd":"0","output":{"iv":"\#(iv)","key":"\#(key)"}}}"#)
        #expect(d.aesKey == key)

        var f = Array(repeating: "", count: 20)
        f[4] = "02"; f[8] = "005930"; f[9] = "10"; f[10] = "70000"; f[11] = "093015"; f[13] = "1"; f[16] = "10"
        let cipher = encrypt(f.joined(separator: "^"), key: key, iv: iv)
        guard case .event(.execution(let e)) = d.decode("1|H0STCNI0|001|" + cipher) else {
            Issue.record("not an execution"); return
        }
        #expect(e.side == .buy)
        #expect(e.code == "005930")
        #expect(e.execQty == 10)
        #expect(e.execPrice == 70_000)
    }

    @Test func ignoresNonExecutionNotices() {
        var d = RealtimeDecoder()
        var f = Array(repeating: "", count: 20)
        f[13] = "2"   // 접수/확인
        #expect(d.decode("0|H0STCNI0|001|" + f.joined(separator: "^")) == .ignored)
    }

    private func encrypt(_ text: String, key: String, iv: String) -> String {
        let plain = Data(text.utf8)
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        var n = 0
        let status = out.withUnsafeMutableBytes { o in
            plain.withUnsafeBytes { p in
                Data(key.utf8).withUnsafeBytes { k in
                    Data(iv.utf8).withUnsafeBytes { i in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, 32, i.baseAddress, p.baseAddress, plain.count, o.baseAddress, o.count, &n)
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        return out.prefix(n).base64EncodedString()
    }
}

@Suite struct StockMasterTests {
    /// 고정폭 마스터 한 줄: 코드(9) + 표준코드(12) + 이름 + 속성(attrLen)
    private func line(code: String, name: String, exchange: StockMaster.Exchange, prev: Int, halt: Bool, designated: Bool) -> String {
        var attrs = Array(repeating: Character(" "), count: exchange.attrLen)
        for (i, c) in String(format: "%09d", prev).enumerated() { attrs[exchange.prevAt + i] = c }
        attrs[exchange.haltAt] = halt ? "Y" : "N"
        attrs[exchange.designatedAt] = designated ? "Y" : "N"
        return code.padding(toLength: 9, withPad: " ", startingAt: 0) + "KR7000000000" + name + String(attrs)
    }

    @Test(arguments: [StockMaster.Exchange.kospi, .kosdaq])
    func parsesKoreanNamesAndFlags(exchange: StockMaster.Exchange) {
        let text = line(code: "005930", name: "삼성전자", exchange: exchange, prev: 70_000, halt: false, designated: false) + "\n"
            + line(code: "000660", name: "SK하이닉스", exchange: exchange, prev: 12_300, halt: true, designated: true) + "\n"
        let cf = CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        let data = text.data(using: enc)!

        let result = StockMaster.parse(mst: data, exchange: exchange)
        #expect(result["005930"] == StockInfo(nameKr: "삼성전자", prevPrice: 70_000, halt: false, designated: false))
        #expect(result["000660"] == StockInfo(nameKr: "SK하이닉스", prevPrice: 12_300, halt: true, designated: true))
    }

    @Test func unzipsDeflatedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = String(repeating: "hello desk kei\n", count: 200)
        try payload.write(to: dir.appendingPathComponent("a.mst"), atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "a.zip", "a.mst"]
        try p.run(); p.waitUntilExit()

        let zip = try Data(contentsOf: dir.appendingPathComponent("a.zip"))
        #expect(String(data: try StockMaster.unzipFirst(zip), encoding: .utf8) == payload)
        #expect(throws: KisError.self) { try StockMaster.unzipFirst(Data([1, 2, 3])) }
    }

    @Test func cacheValidityFollowsUploadSchedule() {
        func kst(_ day: Int, _ h: Int, _ m: Int) -> Date {
            var c = DateComponents(); c.year = 2026; c.month = 3; c.day = day; c.hour = h; c.minute = m
            return MarketClock.calendar.date(from: c)!
        }
        // 10:00 에는 09:46 갱신분이 기준
        #expect(StockMaster.isCacheValid(kst(10, 9, 50), now: kst(10, 10, 0)))
        #expect(!StockMaster.isCacheValid(kst(10, 9, 40), now: kst(10, 10, 0)))
        // 첫 갱신(06:00) 전에는 전날 18:55 이후 캐시면 유효
        #expect(StockMaster.isCacheValid(kst(9, 19, 0), now: kst(10, 5, 0)))
        #expect(!StockMaster.isCacheValid(kst(9, 18, 0), now: kst(10, 5, 0)))
    }
}

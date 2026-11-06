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

    @Test func appStateKeepsLegacyFileWithoutAppearance() throws {
        let legacy = Data(#"{"lastTab":"order","activeGroup":3}"#.utf8)
        let state = try JSONDecoder().decode(AppStateFile.self, from: legacy)
        #expect(state.lastTab == "order")
        #expect(state.activeGroup == 3)
        #expect(state.appearance == "system")
        #expect(state.confirmOrders)
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

@Suite struct MinuteChartTests {
    @Test func parsesTodaysBarsInOrder() {
        let rows: [[String: Any]] = [
            ["stck_bsop_date": "20261030", "stck_cntg_hour": "091500", "stck_prpr": "100"],
            ["stck_bsop_date": "20261030", "stck_cntg_hour": "091400", "stck_prpr": "99"],
            ["stck_bsop_date": "20261029", "stck_cntg_hour": "091300", "stck_prpr": "98"],
            ["stck_bsop_date": "20261030", "stck_cntg_hour": "073000", "stck_prpr": "97"],
        ]
        #expect(MinuteChart.bars(from: rows, date: "20261030")
                == [MinuteBar(minute: 554, price: 99), MinuteBar(minute: 555, price: 100)])
    }

    @Test func upsertUpdatesSameMinuteAndAppendsNewer() {
        var bars = [MinuteBar(minute: 600, price: 1)]
        MinuteChart.upsert(&bars, minute: 600, price: 2)
        MinuteChart.upsert(&bars, minute: 601, price: 3)
        MinuteChart.upsert(&bars, minute: 599, price: 9)    // 과거 분은 무시
        MinuteChart.upsert(&bars, minute: 1300, price: 9)   // 20:00 이후는 무시
        #expect(bars == [MinuteBar(minute: 600, price: 2), MinuteBar(minute: 601, price: 3)])
    }
}

@Suite struct CandleSeriesTests {
    private func kst(_ h: Int, _ m: Int) -> Int {
        var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 10; c.hour = h; c.minute = m
        return Int(MarketClock.calendar.date(from: c)!.timeIntervalSince1970 * 1000)
    }

    @Test func aggregatesMinuteBarsIntoFiveMinuteCandles() {
        let bars = [
            Candle(timestamp: kst(9, 0), open: 100, high: 105, low: 99, close: 102, volume: 10),
            Candle(timestamp: kst(9, 1), open: 102, high: 110, low: 101, close: 108, volume: 20),
            Candle(timestamp: kst(9, 4), open: 108, high: 109, low: 95, close: 96, volume: 30),
            Candle(timestamp: kst(9, 5), open: 96, high: 97, low: 94, close: 95, volume: 5),
        ]
        #expect(CandleSeries.aggregate(bars, minutes: 5) == [
            Candle(timestamp: kst(9, 0), open: 100, high: 110, low: 95, close: 96, volume: 60),
            Candle(timestamp: kst(9, 5), open: 96, high: 97, low: 94, close: 95, volume: 5),
        ])
        #expect(CandleSeries.aggregate(bars, minutes: 1) == bars)
    }

    @Test func mergeSortsAndKeepsLaterDuplicate() {
        let a = Candle(timestamp: 2, open: 1, high: 1, low: 1, close: 1, volume: 1)
        let b = Candle(timestamp: 1, open: 2, high: 2, low: 2, close: 2, volume: 2)
        let a2 = Candle(timestamp: 2, open: 3, high: 3, low: 3, close: 3, volume: 3)
        #expect(CandleSeries.merge([a, b, a2]) == [b, a2])
    }
}

@Suite struct FuturesMasterTests {
    /// 실제 fo_stk_code_mts 파일에서 가져온 줄 (스프레드 포함)
    private static let sample = """
    1|A11611|KR4A116B0004|삼성전자   F 202611 (  10)| |00000.00|1|005930|삼성전자
    1|A11612|KR4A116C0003|삼성전자   F 202612 (  10)| |00000.00|2|005930|삼성전자
    2|4GNW0401|KR44GNW4W5S8|삼성전자   SP 2611-2612 (  10)| |00000.00|1|005930|삼성전자
    5|B11611089|KR4B116B0895|삼성전자   C 202611   190,000(  10)|2|00190000| |005930|삼성전자
    6|C11611089|KR4C116B0894|삼성전자   P 202611   190,000(  10)|3|00190000| |005930|삼성전자
    5|B11612089|KR4B116C0894|삼성전자   C 202612   195,000(  10)|2|00195000| |005930|삼성전자
    7|AM0612|KR4AM06C0009|KODEX 삼성그룹 F 202612| |00000.00|1|102780|KODEX 삼성그룹
    1|1GNW04|KR41GNW40002|금양       F 202504 (  10)| |00000.00|1|001570|금양
    """

    private func parsed() -> [FuturesInstrument] {
        FuturesMaster.parse(mst: Data(Self.sample.utf8))
    }

    @Test func parsesKindsAndSkipsSpreads() {
        let items = parsed()
        #expect(items.count == 7)
        #expect(!items.contains { $0.code == "4GNW0401" })
        let call = items.first { $0.code == "B11611089" }!
        #expect(call.kind == .call && call.strike == 190_000 && call.expiry == "202611")
        #expect(call.underlyingCode == "005930" && call.underlyingName == "삼성전자" && call.multiplier == 10)
        #expect(items.first { $0.code == "C11611089" }?.kind == .put)
        let future = items.first { $0.code == "A11612" }!
        #expect(future.kind == .future && future.strike == 0 && future.expiry == "202612")
        #expect(future.title == "삼성전자 선물 26.12")
        #expect(call.title == "삼성전자 콜 26.11 190,000")
    }

    @Test func multiplierUnknownForEtfFutures() {
        #expect(parsed().first { $0.code == "AM0612" }?.multiplier == 0)
    }

    @Test func multiplierOfAdjustedContract() {
        #expect(FuturesMaster.multiplier(in: "삼성바이오 F 202611 (  10)*") == 10)
        #expect(FuturesMaster.multiplier(in: "삼성전자   C 202611   190,000(  10)") == 10)
        #expect(FuturesMaster.expiry(in: "삼성바이오 F 202611 (  10)*") == "202611")
    }

    @Test func dropsExpiredMonths() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 7; c.hour = 12
        let now = MarketClock.calendar.date(from: c)!
        let active = FuturesMaster.active(parsed(), now: now)
        #expect(!active.contains { $0.expiry == "202504" })
        #expect(active.contains { $0.expiry == "202611" })
    }

    @Test func catalogSelection() {
        let catalog = FuturesCatalog(instruments: parsed())
        #expect(catalog.expiries(underlying: "005930", kind: .future) == ["202611", "202612"])
        #expect(catalog.expiries(underlying: "005930", kind: .call) == ["202611", "202612"])
        #expect(catalog.strikes(underlying: "005930", kind: .call, expiry: "202612") == [195_000])
        #expect(catalog.instrument(underlying: "005930", kind: .put, expiry: "202611", strike: 190_000)?.code == "C11611089")
        #expect(catalog.instrument(underlying: "005930", kind: .put, expiry: "202612", strike: 190_000) == nil)
    }

    @Test func catalogSearch() {
        let catalog = FuturesCatalog(instruments: parsed())
        // 이름이 검색어로 시작하는 기초자산이 먼저, 그다음 이름에 포함하는 기초자산. 각각 만기 월별 선물로 펼친다.
        let results = catalog.search("삼성", limit: 8)
        #expect(results.map(\.key) == ["A11611", "A11612", "AM0612"])
        #expect(results.map(\.name) == ["삼성전자 선물 26.11", "삼성전자 선물 26.12", "KODEX 삼성그룹 선물 26.12"])
        #expect(catalog.search("005930", limit: 8).map(\.key) == ["A11611", "A11612"])
        #expect(catalog.search("삼성", limit: 2).count == 2)
        #expect(catalog.search("", limit: 8).isEmpty)
        // 단축코드 앞부분으로도 종목을 바로 찾는다.
        #expect(catalog.search("A1161", limit: 8).map(\.key) == ["A11611"])
        // 선물이 없는 기초자산은 기초자산 키로 돌려준다.
        let optionsOnly = FuturesCatalog(instruments: parsed().filter { $0.kind != .future })
        #expect(optionsOnly.search("삼성전자", limit: 8).map(\.key) == ["u:005930"])
        #expect(FuturesCatalog.underlyingCode(fromKey: "u:005930") == "005930")
        #expect(FuturesCatalog.underlyingCode(fromKey: "A11611") == nil)
    }

    @Test func tickInferenceAndStep() {
        let futures = OrderBook(code: "A11612",
                                asks: [189_000, 189_100, 189_200].map { OrderBookLevel(price: $0, qty: 1) },
                                bids: [188_700, 188_600, 0].map { OrderBookLevel(price: $0, qty: 1) })
        #expect(inferTick(futures) == 100)
        #expect(inferTick(nil) == 1)
        #expect(stepPrice(189_000, up: true, tick: 100) == 189_100)
        #expect(stepPrice(189_050, up: true, tick: 100) == 189_100)
        #expect(stepPrice(189_050, up: false, tick: 100) == 189_000)
        #expect(stepPrice(100, up: false, tick: 100) == 100)
    }

    @Test func futuresAccountUsesProduct03() {
        #expect(KisAccount(accountNo: "12345678-01").futuresAccountParts == ("12345678", "03"))
        #expect(KisAccount(accountNo: "1234567801").futuresAccountParts == ("12345678", "03"))
        #expect(KisAccount(accountNo: "12345678-03").futuresAccountParts == ("12345678", "03"))
        #expect(KisAccount(accountNo: "12345678").futuresAccountParts == ("12345678", "03"))
    }
}

@Suite struct FuturesRealtimeBookTests {
    /// 주식선물 호가 68필드: 매도 189000.. 매수 188900.. 로 100원씩, 잔량은 1.. / 101..
    private func futuresFields() -> [String] {
        var f = Array(repeating: "0", count: 68)
        f[0] = "A11611"; f[1] = "154500"
        for i in 0..<10 {
            f[2 + i] = "\(189_000 + i * 100).00"
            f[12 + i] = "\(188_900 - i * 100).00"
            f[42 + i] = String(1 + i)
            f[52 + i] = String(101 + i)
        }
        return f
    }

    /// 주식옵션 호가 68필드: 1~5호가가 앞에, 6~10호가가 뒤에 붙는다.
    private func optionFields(deep: Bool) -> [String] {
        var f = Array(repeating: "0", count: 68)
        f[0] = "B11611089"; f[1] = "154500"
        for i in 0..<5 {
            f[2 + i] = String(1_000 + i * 10); f[7 + i] = String(990 - i * 10)
            f[22 + i] = String(1 + i); f[27 + i] = String(101 + i)
            if deep {
                f[38 + i] = String(1_050 + i * 10); f[43 + i] = String(940 - i * 10)
                f[58 + i] = String(6 + i); f[63 + i] = String(106 + i)
            }
        }
        return f
    }

    @Test func futuresTenLevels() {
        let book = RealtimeDecoder.futuresOrderBook(futuresFields(), option: false)!
        #expect(book.code == "A11611")
        #expect(book.asks.count == 10 && book.bids.count == 10)
        #expect(book.asks[0] == OrderBookLevel(price: 189_000, qty: 1))
        #expect(book.asks[9] == OrderBookLevel(price: 189_900, qty: 10))
        #expect(book.bids[0] == OrderBookLevel(price: 188_900, qty: 101))
        #expect(book.bids[9] == OrderBookLevel(price: 188_000, qty: 110))
    }

    @Test func optionDeepLevelsAreAppended() {
        let book = RealtimeDecoder.futuresOrderBook(optionFields(deep: true), option: true)!
        #expect(book.asks.count == 10 && book.bids.count == 10)
        #expect(book.asks[0] == OrderBookLevel(price: 1_000, qty: 1))
        #expect(book.asks[4] == OrderBookLevel(price: 1_040, qty: 5))
        #expect(book.asks[5] == OrderBookLevel(price: 1_050, qty: 6))
        #expect(book.asks[9] == OrderBookLevel(price: 1_090, qty: 10))
        #expect(book.bids[0] == OrderBookLevel(price: 990, qty: 101))
        #expect(book.bids[5] == OrderBookLevel(price: 940, qty: 106))
        #expect(book.bids[9] == OrderBookLevel(price: 900, qty: 110))
    }

    @Test func decodesFullMessages() {
        var decoder = RealtimeDecoder()
        let message = "0|H0ZFASP0|001|" + futuresFields().joined(separator: "^")
        guard case .event(.orderBook(let book)) = decoder.decode(message) else { Issue.record("not an order book"); return }
        #expect(book.code == "A11611" && book.asks.count == 10)
        let option = "0|H0ZOASP0|001|" + optionFields(deep: true).joined(separator: "^")
        guard case .event(.orderBook(let ob)) = decoder.decode(option) else { Issue.record("not an order book"); return }
        #expect(ob.code == "B11611089" && ob.bids[9].price == 900)
        #expect(decoder.decode("0|H0ZFASP0|001|A11611^154500") == .ignored)
    }

    @Test func trimsEmptyDeepLevelsOnly() {
        // 6~10호가가 비어 있으면 5호가로 줄고, 앞 5단계는 비어 있어도 남는다.
        let shallow = RealtimeDecoder.futuresOrderBook(optionFields(deep: false), option: true)!
        #expect(shallow.asks.count == 10)
        let trimmed = shallow.trimmingEmptyDeepLevels()
        #expect(trimmed.asks.count == 5 && trimmed.bids.count == 5)
        let sparse = OrderBook(code: "X", asks: [OrderBookLevel(price: 100, qty: 1)] + Array(repeating: OrderBookLevel(price: 0, qty: 0), count: 9),
                               bids: [])
        #expect(sparse.trimmingEmptyDeepLevels().asks.count == 5)
        let deep = RealtimeDecoder.futuresOrderBook(optionFields(deep: true), option: true)!
        #expect(deep.trimmingEmptyDeepLevels().asks.count == 10)
    }
}

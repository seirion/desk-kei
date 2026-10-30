import DeskKeiCore
import SwiftUI
import WebKit

/// KLineChart(Resources/klinecharts.min.js) 를 WKWebView 에 올리고 Swift 와 데이터를 주고받는다.
/// 차트가 필요한 봉은 `getBars` 메시지로 요청하고, 조회한 결과를 `kei.deliver` 로 돌려준다.
@MainActor
final class ChartController: NSObject, ObservableObject {
    /// 마우스가 가리키는 봉 (없으면 nil)
    @Published private(set) var hovered: Candle?
    /// 차트의 가장 최근 봉
    @Published private(set) var latest: Candle?
    @Published private(set) var indicators: Set<String> = []
    @Published private(set) var period: ChartPeriod = .minute(1)
    @Published private(set) var errorMessage: String?

    let webView: WKWebView
    var client: () -> KisClient? = { nil }

    private var ready = false
    private var code = ""
    private var requested = ""
    /// 분봉을 합치기 위한 1분봉 원본 (현재 종목)
    private var minuteRaw: [Candle] = []
    private var generation = 0

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakScriptHandler(self), name: "bridge")
        webView.setValue(false, forKey: "drawsBackground")
        loadPage()
    }

    // MARK: 화면에서 쓰는 동작

    func show(code newCode: String) {
        code = newCode
        applySymbolIfReady()
    }

    func setPeriod(_ newPeriod: ChartPeriod) {
        guard newPeriod != period else { return }
        period = newPeriod
        guard ready else { return }
        let (type, span) = newPeriod.jsArguments
        run("kei.setPeriod('\(type)', \(span))")
    }

    func tick(_ trade: RealTimeTrade) {
        guard ready, trade.code == code else { return }
        run("kei.tick(\(trade.price), \(trade.volume), \(Int(Date().timeIntervalSince1970 * 1000)))")
    }

    func draw(_ tool: String) { run("kei.draw('\(tool)')") }
    func clearDrawings() { run("kei.clearDrawings()") }
    func toggleIndicator(_ name: String, onCandle: Bool) { run("kei.toggleIndicator('\(name)', \(onCandle))") }

    // MARK: 페이지

    private func loadPage() {
        guard let html = Self.resource("chart", "html"), let chartJS = Self.resource("klinecharts.min", "js") else {
            errorMessage = "차트 리소스를 찾을 수 없습니다."
            return
        }
        webView.loadHTMLString(html.replacingOccurrences(of: "/*KLINECHARTS*/", with: chartJS), baseURL: nil)
    }

    /// 앱 번들(Contents/Resources)에서 찾고, `swift run` 처럼 번들이 없으면 저장소의 Resources 에서 찾는다.
    private static func resource(_ name: String, _ ext: String) -> String? {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [Bundle.main.url(forResource: name, withExtension: ext),
                          repoRoot.appendingPathComponent("Resources/\(name).\(ext)")]
        for url in candidates.compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return nil
    }

    private func applySymbolIfReady() {
        guard ready, !code.isEmpty, code != requested else { return }
        requested = code
        hovered = nil
        latest = nil
        minuteRaw = []
        generation += 1
        run("kei.setSymbol('\(code)')")
    }

    private func run(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: 봉 조회

    private func loadBars(id: Int, loadType: String, timestamp: Double?, period: ChartPeriod, ticker: String) {
        guard let client = client(), loadType == "init" || loadType == "forward" else {
            deliver(id, bars: [], more: false)
            return
        }
        let generation = generation
        Task {
            do {
                let (bars, more) = try await fetch(client, ticker, period, loadType, timestamp)
                guard generation == self.generation else { return }
                errorMessage = nil
                deliver(id, bars: bars, more: more)
            } catch {
                guard generation == self.generation else { return }
                errorMessage = "차트를 불러오지 못했습니다: \(error.localizedDescription)"
                deliver(id, bars: [], more: false)
            }
        }
    }

    private func fetch(_ client: KisClient, _ ticker: String, _ period: ChartPeriod,
                       _ loadType: String, _ timestamp: Double?) async throws -> (bars: [Candle], more: Bool) {
        // KLineChart 에서 forward 는 더 오래된 봉을 요청하는 것이다.
        let older = loadType == "forward"
        switch period {
        case .minute(let span):
            if !older { minuteRaw = [] }
            let before = older ? minuteRaw.first.map { Date(timeIntervalSince1970: Double($0.timestamp) / 1000) } : nil
            let page = try await client.minuteCandles(code: ticker, before: before)
            minuteRaw = CandleSeries.merge(page + minuteRaw)
            var bars = CandleSeries.aggregate(minuteRaw, minutes: span)
            if older, let timestamp { bars = bars.filter { Double($0.timestamp) < timestamp } }
            return (bars, !page.isEmpty)
        case .day, .week, .month:
            let before = older ? timestamp.map { Date(timeIntervalSince1970: $0 / 1000) } : nil
            let page = try await client.periodCandles(code: ticker, period: period, endBefore: before)
            return (page, page.count >= 100)
        }
    }

    private func deliver(_ id: Int, bars: [Candle], more: Bool) {
        guard let data = try? JSONEncoder().encode(bars), let json = String(data: data, encoding: .utf8) else { return }
        run("kei.deliver(\(id), \(json), \(more))")
    }

    // MARK: 자바스크립트 메시지

    fileprivate func receive(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            ready = true
            let (type, span) = period.jsArguments
            run("kei.setPeriod('\(type)', \(span))")
            applySymbolIfReady()
        case "getBars":
            let periodInfo = body["period"] as? [String: Any]
            guard let id = body["id"] as? Int,
                  let loadType = body["loadType"] as? String,
                  let ticker = body["ticker"] as? String,
                  let period = ChartPeriod(type: periodInfo?["type"] as? String ?? "", span: periodInfo?["span"] as? Int ?? 1)
            else { return }
            loadBars(id: id, loadType: loadType, timestamp: body["timestamp"] as? Double, period: period, ticker: ticker)
        case "hover":
            hovered = Self.candle(body["bar"])
        case "latest":
            latest = Self.candle(body["bar"])
        case "indicators":
            indicators = Set((body["active"] as? [String]) ?? [])
        default:
            break
        }
    }

    private static func candle(_ value: Any?) -> Candle? {
        guard let o = value as? [String: Any], let ts = o["timestamp"] as? Double else { return nil }
        func n(_ key: String) -> Int { Int((o[key] as? Double) ?? 0) }
        return Candle(timestamp: Int(ts), open: n("open"), high: n("high"), low: n("low"), close: n("close"), volume: n("volume"))
    }
}

private extension ChartPeriod {
    var jsArguments: (type: String, span: Int) {
        switch self {
        case .minute(let span): return ("minute", span)
        case .day: return ("day", 1)
        case .week: return ("week", 1)
        case .month: return ("month", 1)
        }
    }
}

/// WKUserContentController 가 핸들러를 강하게 잡아 생기는 순환 참조를 피한다.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: ChartController?
    init(_ target: ChartController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor in self.target?.receive(body) }
    }
}

struct ChartWebView: NSViewRepresentable {
    let controller: ChartController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

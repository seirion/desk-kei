import DeskKeiCore
import SwiftUI

/// 주문 화면의 차트 탭: 상단에 종목·실시간 가격·OHLCV, 아래에 캔들 차트.
struct ChartView: View {
    @StateObject private var chart = ChartController()

    let live: LiveMarket
    let client: () -> KisClient?
    let code: String
    let name: String
    let currentPrice: KisPrice?
    let recent: [RecentStock]
    let onRemoveRecent: (_ code: String) -> Void
    let onSelect: (_ code: String, _ name: String) -> Void

    private static let periods: [(label: String, period: ChartPeriod)] = [
        ("1분", .minute(1)), ("3분", .minute(3)), ("5분", .minute(5)), ("10분", .minute(10)), ("15분", .minute(15)),
        ("30분", .minute(30)), ("60분", .minute(60)),
        ("일", .day), ("주", .week), ("월", .month),
    ]
    private static let drawingTools: [(label: String, name: String)] = [
        ("추세선", "segment"), ("직선", "straightLine"), ("반직선", "rayLine"),
        ("수평선", "horizontalStraightLine"), ("수직선", "verticalStraightLine"),
        ("평행선", "parallelStraightLine"), ("가격 채널", "priceChannelLine"), ("피보나치", "fibonacciLine"),
    ]
    private static let candleIndicators = [("이동평균 (MA)", "MA"), ("볼린저밴드 (BOLL)", "BOLL")]
    private static let paneIndicators = [("거래량 (VOL)", "VOL"), ("MACD", "MACD"), ("RSI", "RSI"), ("KDJ", "KDJ")]

    var body: some View {
        VStack(spacing: 0) {
            StockSearchField(selectedCode: code, recent: recent, onRemoveRecent: onRemoveRecent, floating: true, onSelect: onSelect)
                .frame(width: 300)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            header
            Divider()
            toolbar
            if let message = chart.errorMessage {
                ErrorBanner(text: message).padding(8)
            }
            ChartWebView(controller: chart)
        }
        .onAppear {
            chart.client = client
            chart.show(code: code)
        }
        .onChange(of: code) { chart.show(code: $0) }
        .onReceive(live.$liveTrade.compactMap { $0 }) { chart.tick($0) }
    }

    // MARK: 상단 정보

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name.isEmpty ? "종목을 선택하세요" : name).font(.title3).fontWeight(.bold)
                Text(code).font(.caption).foregroundStyle(.secondary)
                Spacer()
                PriceLabel(live: live, code: code, currentPrice: currentPrice)
            }
            CandleReadoutView(readout: chart.readout, period: chart.period)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: 도구 모음

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("주기", selection: Binding(get: { chart.period }, set: { chart.setPeriod($0) })) {
                ForEach(Self.periods, id: \.label) { Text($0.label).tag($0.period) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 420)

            Spacer()

            Menu("지표") {
                ForEach(Self.candleIndicators, id: \.1) { item in indicatorButton(item.0, item.1, onCandle: true) }
                Divider()
                ForEach(Self.paneIndicators, id: \.1) { item in indicatorButton(item.0, item.1, onCandle: false) }
            }
            .fixedSize()

            Menu("그리기") {
                ForEach(Self.drawingTools, id: \.name) { tool in
                    Button(tool.label) { chart.draw(tool.name) }
                }
                Divider()
                Button("모두 지우기", role: .destructive) { chart.clearDrawings() }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func indicatorButton(_ label: String, _ name: String, onCandle: Bool) -> some View {
        Button {
            chart.toggleIndicator(name, onCandle: onCandle)
        } label: {
            if chart.indicators.contains(name) { Label(label, systemImage: "checkmark") } else { Text(label) }
        }
    }
}

/// 실시간 체결가. 체결마다 갱신되므로 차트 화면과 분리해 이 뷰만 다시 그린다.
private struct PriceLabel: View {
    @ObservedObject var live: LiveMarket
    let code: String
    let currentPrice: KisPrice?

    var body: some View {
        let trade = live.liveTrade?.code == code ? live.liveTrade : nil
        if let price = trade?.price ?? currentPrice?.price {
            let change = trade?.change ?? currentPrice?.change ?? 0
            let sign = trade?.sign ?? currentPrice?.sign ?? "3"
            let rate = trade?.rate ?? currentPrice?.rate ?? 0
            let c = formatChange(change: change, sign: sign, rate: nil)
            HStack(spacing: 6) {
                Text(fmt(price)).font(.title2).fontWeight(.bold)
                Text("\(c.text) (\(String(format: "%.2f", rate))%)").font(.callout)
            }
            .foregroundStyle(color(for: c.direction))
            .monospacedDigit()
        }
    }
}

/// 마우스가 가리키는 봉(없으면 최근 봉)의 시·고·저·종·거래량. 마우스 이동마다 바뀌므로 분리해 둔다.
private struct CandleReadoutView: View {
    @ObservedObject var readout: ChartReadout
    let period: ChartPeriod

    private static let minuteFormat = timeFormatter("MM/dd HH:mm")
    private static let dayFormat = timeFormatter("yyyy/MM/dd")

    private static func timeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        f.dateFormat = format
        return f
    }

    var body: some View {
        if let c = readout.hovered ?? readout.latest {
            HStack(spacing: 14) {
                Text(time(c)).font(.caption).foregroundStyle(.secondary)
                value("시", fmt(c.open), .primary)
                value("고", fmt(c.high), .up)
                value("저", fmt(c.low), .down)
                value("종", fmt(c.close), .primary)
                value("량", fmt(c.volume), .primary)
            }
            .font(.callout).monospacedDigit()
        } else {
            Text(" ").font(.callout)
        }
    }

    private func value(_ label: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(tint == .primary ? Color.secondary : tint).font(.caption)
            Text(text).foregroundStyle(tint)
        }
    }

    private func time(_ c: Candle) -> String {
        let formatter: DateFormatter
        switch period {
        case .minute: formatter = Self.minuteFormat
        default: formatter = Self.dayFormat
        }
        return formatter.string(from: Date(timeIntervalSince1970: Double(c.timestamp) / 1000))
    }
}

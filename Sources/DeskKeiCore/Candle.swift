import Foundation

/// OHLCV 봉. timestamp 는 봉이 시작하는 시각(epoch 밀리초).
public struct Candle: Codable, Equatable {
    public var timestamp: Int
    public var open: Int
    public var high: Int
    public var low: Int
    public var close: Int
    public var volume: Int
    public init(timestamp: Int, open: Int, high: Int, low: Int, close: Int, volume: Int) {
        self.timestamp = timestamp
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}

public enum ChartPeriod: Hashable {
    case minute(Int)
    case day, week, month

    public init?(type: String, span: Int) {
        switch type {
        case "minute": self = .minute(max(span, 1))
        case "day": self = .day
        case "week": self = .week
        case "month": self = .month
        default: return nil
        }
    }

    /// KIS 기간 구분 코드 (일/주/월봉)
    var kisCode: String {
        switch self {
        case .week: return "W"
        case .month: return "M"
        default: return "D"
        }
    }
}

public enum CandleSeries {
    static let kstOffsetMs = 9 * 3600 * 1000

    /// 시각 순으로 정렬하고 같은 시각이 겹치면 뒤에 있는 값을 쓴다.
    public static func merge(_ candles: [Candle]) -> [Candle] {
        var byTime: [Int: Candle] = [:]
        for c in candles { byTime[c.timestamp] = c }
        return byTime.keys.sorted().map { byTime[$0]! }
    }

    /// 1분봉을 `minutes` 분봉으로 합친다. 구간은 한국 시간의 정시를 기준으로 나눈다.
    public static func aggregate(_ bars: [Candle], minutes: Int) -> [Candle] {
        guard minutes > 1 else { return bars }
        let span = minutes * 60_000
        var result: [Candle] = []
        for bar in bars {
            let bucket = (bar.timestamp + kstOffsetMs) / span * span - kstOffsetMs
            if var last = result.last, last.timestamp == bucket {
                last.high = max(last.high, bar.high)
                last.low = min(last.low, bar.low)
                last.close = bar.close
                last.volume += bar.volume
                result[result.count - 1] = last
            } else {
                result.append(Candle(timestamp: bucket, open: bar.open, high: bar.high,
                                     low: bar.low, close: bar.close, volume: bar.volume))
            }
        }
        return result
    }
}

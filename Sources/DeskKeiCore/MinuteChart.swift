import Foundation

/// 1분봉 종가 한 점. minute 은 자정부터의 분.
public struct MinuteBar: Equatable {
    public var minute: Int
    public var price: Int
    public init(minute: Int, price: Int) {
        self.minute = minute
        self.price = price
    }
}

public enum MinuteChart {
    /// 차트의 가로축: NXT 프리마켓 시작(08:00) ~ 애프터 종료(20:00)
    public static let startMinute = 8 * 60
    public static let endMinute = 20 * 60

    /// KIS 분봉 응답 행을 오늘 것만 시간순으로 변환한다.
    static func bars(from rows: [[String: Any]], date: String) -> [MinuteBar] {
        var result: [MinuteBar] = []
        for row in rows {
            guard str(row["stck_bsop_date"]) == date else { continue }
            let hhmmss = str(row["stck_cntg_hour"])
            guard hhmmss.count == 6, let h = Int(hhmmss.prefix(2)), let m = Int(hhmmss.dropFirst(2).prefix(2)) else { continue }
            let minute = h * 60 + m
            let price = int(row["stck_prpr"])
            guard price > 0, (startMinute..<endMinute).contains(minute) else { continue }
            result.append(MinuteBar(minute: minute, price: price))
        }
        return merge(result)
    }

    /// 분 기준으로 정렬하고 같은 분이 겹치면 뒤에 있는 값을 쓴다.
    public static func merge(_ bars: [MinuteBar]) -> [MinuteBar] {
        var byMinute: [Int: Int] = [:]
        for b in bars { byMinute[b.minute] = b.price }
        return byMinute.keys.sorted().map { MinuteBar(minute: $0, price: byMinute[$0]!) }
    }

    /// 실시간 체결가를 해당 분에 반영한다.
    public static func upsert(_ bars: inout [MinuteBar], minute: Int, price: Int) {
        guard (startMinute..<endMinute).contains(minute), price > 0 else { return }
        if let last = bars.last, last.minute == minute {
            bars[bars.count - 1].price = price
        } else if let last = bars.last, last.minute > minute {
            return
        } else {
            bars.append(MinuteBar(minute: minute, price: price))
        }
    }
}

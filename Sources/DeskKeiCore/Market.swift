import Foundation

/// 장 시간 판단 (한국 시간 기준)
public enum MarketClock {
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return cal
    }()

    public static func minutes(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// NXT 운영 시간: 08:00~09:00, 15:30~20:00
    public static func isNxtHour(_ date: Date = Date()) -> Bool {
        let m = minutes(date)
        return (m >= 8 * 60 && m < 9 * 60) || (m >= 15 * 60 + 30 && m < 20 * 60)
    }

    /// 정규장: 09:00~15:30
    public static func isRegularHour(_ date: Date = Date()) -> Bool {
        let m = minutes(date)
        return m >= 9 * 60 && m < 15 * 60 + 30
    }

    /// KRX 애프터마켓: 16:00~20:00. 시장가 주문이 없고 지정가는 주문구분 41 을 쓴다.
    public static func isKrxAfterMarket(_ date: Date = Date()) -> Bool {
        let m = minutes(date)
        return m >= 16 * 60 && m < 20 * 60
    }

    /// 지정가 주문구분 코드. 애프터마켓에서는 00 대신 41.
    public static func limitOrderDivision(_ date: Date = Date()) -> String {
        isKrxAfterMarket(date) ? "41" : "00"
    }

    /// 오늘 날짜 yyyyMMdd (한국 시간)
    public static func todayString(_ date: Date = Date()) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// 국내 주식 호가 단위
public func tickSize(_ price: Int) -> Int {
    switch price {
    case ..<2_000: return 1
    case ..<5_000: return 5
    case ..<20_000: return 10
    case ..<50_000: return 50
    case ..<100_000: return 100
    case ..<500_000: return 500
    default: return 1_000
    }
}

public func stepPrice(_ price: Int, up: Bool) -> Int {
    let tick = tickSize(price)
    return max(1, up ? price + tick : price - tick)
}

private let groupingFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = ","
    f.usesGroupingSeparator = true
    f.locale = Locale(identifier: "en_US")
    return f
}()

public func fmt(_ n: Int) -> String {
    groupingFormatter.string(from: NSNumber(value: n)) ?? String(n)
}

public func fmtSigned(_ n: Int) -> String {
    n > 0 ? "+\(fmt(n))" : fmt(n)
}

public func fmtRate(_ r: Double, signed: Bool = true) -> String {
    let s = String(format: "%.2f", abs(r))
    if !signed { return "\(s)%" }
    return "\(r > 0 ? "+" : r < 0 ? "-" : "")\(s)%"
}

/// 등락 표시 문자열: "+1,000 (+1.23%)"
public func formatChange(change: Int, sign: String, rate: Double?) -> (text: String, direction: PriceDirection) {
    let dir = priceDirection(sign: sign)
    if change == 0 { return ("0", .flat) }
    let prefix = dir == .up ? "+" : dir == .down ? "-" : ""
    var text = "\(prefix)\(fmt(abs(change)))"
    if let rate { text += " (\(prefix)\(String(format: "%.2f", abs(rate)))%)" }
    return (text, dir)
}

/// 체결 시각 HHMMSS → HH:MM:SS
public func formatOrderTime(_ t: String) -> String {
    guard t.count >= 6 else { return t }
    let chars = Array(t)
    return "\(String(chars[0..<2])):\(String(chars[2..<4])):\(String(chars[4..<6]))"
}

/// 거래량 축약 표시
public func formatVolume(_ v: Int) -> String {
    if v >= 1_000_000 { return String(format: "%.1fM", Double(v) / 1_000_000) }
    if v >= 1_000 { return String(format: "%.0fK", Double(v) / 1_000) }
    return fmt(v)
}

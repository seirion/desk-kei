import Foundation
import CommonCrypto

public enum RealtimeEvent: Equatable {
    case trade(RealTimeTrade)
    case orderBook(OrderBook)
    case execution(OrderExecution)
}

public enum RealtimeMessage: Equatable {
    case ping(String)           // 그대로 되돌려 보내야 하는 PINGPONG
    case event(RealtimeEvent)
    case ignored
}

/// KIS 실시간 WebSocket 메시지 해석기.
/// 체결통보(H0STCNI0)는 AES-256-CBC 로 암호화되어 오며, 키/IV 는 구독 응답으로 받는다.
public struct RealtimeDecoder {
    public private(set) var aesKey: String?
    public private(set) var aesIV: String?

    public init() {}

    public mutating func decode(_ raw: String) -> RealtimeMessage {
        if raw == "PINGPONG" { return .ping(raw) }

        if raw.hasPrefix("{") {
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
            let header = json["header"] as? [String: Any]
            let trId = header?["tr_id"] as? String
            if trId == "PINGPONG" { return .ping(raw) }
            if trId == "H0STCNI0",
               let output = (json["body"] as? [String: Any])?["output"] as? [String: Any],
               let key = output["key"] as? String, let iv = output["iv"] as? String {
                aesKey = key
                aesIV = iv
            }
            return .ignored
        }

        // 실시간 데이터: "0|TR_ID|COUNT|DATA" (첫 값이 1이면 암호화)
        let parts = raw.components(separatedBy: "|")
        guard parts.count >= 4 else { return .ignored }
        let trId = parts[1]
        var payload = parts[3]

        if parts[0] == "1" {
            guard let key = aesKey, let iv = aesIV,
                  let plain = Self.decrypt(base64: payload, key: key, iv: iv) else { return .ignored }
            payload = plain
        }
        let fields = payload.components(separatedBy: "^")

        switch trId {
        case "H0STCNT0", "H0NXCNT0":
            return Self.trade(fields, isNxt: trId == "H0NXCNT0").map { .event(.trade($0)) } ?? .ignored
        case "H0STASP0", "H0NXASP0":
            return Self.orderBook(fields).map { .event(.orderBook($0)) } ?? .ignored
        case "H0STCNI0":
            return Self.execution(fields).map { .event(.execution($0)) } ?? .ignored
        default:
            return .ignored
        }
    }

    // MARK: 체결

    // [0]종목 [2]현재가 [3]대비부호 [4]전일대비 [5]등락률 [7]시가 [8]고가 [9]저가 [13]누적거래량
    static func trade(_ f: [String], isNxt: Bool) -> RealTimeTrade? {
        guard f.count >= 6 else { return nil }
        let delta = Double(f[4]) ?? 0
        var sign = f[3]
        if !["1", "2", "3", "4", "5"].contains(sign) {
            sign = delta > 0 ? "2" : delta < 0 ? "5" : "3"
        }
        func at(_ i: Int) -> Int { i < f.count ? Int(Double(f[i]) ?? 0) : 0 }
        return RealTimeTrade(
            code: f[0],
            price: at(2),
            change: Int(abs(delta)),
            sign: sign,
            rate: abs(Double(f[5]) ?? 0),
            volume: at(13),
            open: at(7),
            high: at(8),
            low: at(9),
            isNxt: isNxt
        )
    }

    // MARK: 호가

    // [0]종목, [3..12] 매도호가1~10, [13..22] 매수호가1~10, [23..32] 매도잔량, [33..42] 매수잔량
    static func orderBook(_ f: [String]) -> OrderBook? {
        guard f.count >= 43 else { return nil }
        var asks: [OrderBookLevel] = []
        var bids: [OrderBookLevel] = []
        for i in 0..<10 {
            asks.append(OrderBookLevel(price: Int(Double(f[3 + i]) ?? 0), qty: Int(Double(f[23 + i]) ?? 0)))
            bids.append(OrderBookLevel(price: Int(Double(f[13 + i]) ?? 0), qty: Int(Double(f[33 + i]) ?? 0)))
        }
        return OrderBook(code: f[0], asks: asks, bids: bids)
    }

    // MARK: 체결통보

    // [4]매도매수구분(02=매수) [8]종목 [9]체결수량 [10]체결단가 [11]체결시각 [13]체결여부(1=체결) [16]주문수량
    static func execution(_ f: [String]) -> OrderExecution? {
        guard f.count >= 17, f[13] == "1" else { return nil }
        return OrderExecution(
            code: f[8],
            side: f[4] == "02" ? .buy : .sell,
            execQty: Int(f[9]) ?? 0,
            execPrice: Int(f[10]) ?? 0,
            execTime: f[11],
            orderQty: Int(f[16]) ?? 0
        )
    }

    // MARK: 복호화

    static func decrypt(base64: String, key: String, iv: String) -> String? {
        guard let cipher = Data(base64Encoded: base64),
              let keyData = key.data(using: .utf8), let ivData = iv.data(using: .utf8) else { return nil }
        var out = Data(count: cipher.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            cipher.withUnsafeBytes { inPtr in
                keyData.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                inPtr.baseAddress, cipher.count,
                                outPtr.baseAddress, outPtr.count, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: out.prefix(outLen), encoding: .utf8)
    }
}

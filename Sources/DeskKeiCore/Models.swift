import Foundation

/// KIS 계정 설정. 계정 이름이 식별자다.
public struct KisAccount: Codable, Equatable, Identifiable, Hashable {
    public var name: String
    public var accountNo: String
    public var userId: String
    public var appKey: String
    public var appSecret: String

    public var id: String { name }

    public init(name: String = "", accountNo: String = "", userId: String = "", appKey: String = "", appSecret: String = "") {
        self.name = name
        self.accountNo = accountNo
        self.userId = userId
        self.appKey = appKey
        self.appSecret = appSecret
    }

    public var hasCredentials: Bool { !appKey.isEmpty && !appSecret.isEmpty }
    public var hasTradingAccount: Bool { hasCredentials && !accountNo.isEmpty }

    /// 계좌번호를 (종합계좌 8자리, 상품코드) 로 분리
    public var accountParts: (cano: String, product: String) {
        let clean = accountNo.filter { $0 != "-" && !$0.isWhitespace }
        return (String(clean.prefix(8)), String(clean.dropFirst(8)))
    }
}

public enum PriceDirection { case up, down, flat }

public struct KisPrice: Equatable {
    public var price: Int
    public var prevPrice: Int
    public var change: Int          // 전일 대비 (절댓값)
    public var sign: String         // 1:상한 2:상승 3:보합 4:하한 5:하락
    public var rate: Double         // 등락률 (절댓값)
    public var open: Int
    public var high: Int
    public var low: Int
    public var volume: Int

    public init(price: Int, prevPrice: Int = 0, change: Int = 0, sign: String = "3", rate: Double = 0,
                open: Int = 0, high: Int = 0, low: Int = 0, volume: Int = 0) {
        self.price = price
        self.prevPrice = prevPrice
        self.change = change
        self.sign = sign
        self.rate = rate
        self.open = open
        self.high = high
        self.low = low
        self.volume = volume
    }

    public var direction: PriceDirection { priceDirection(sign: sign) }
}

public func priceDirection(sign: String) -> PriceDirection {
    switch sign {
    case "1", "2": return .up
    case "4", "5": return .down
    default: return .flat
    }
}

public struct OrderBookLevel: Equatable {
    public var price: Int
    public var qty: Int
    public init(price: Int, qty: Int) {
        self.price = price
        self.qty = qty
    }
}

/// asks[0] = 최우선 매도(가장 낮음), bids[0] = 최우선 매수(가장 높음)
public struct OrderBook: Equatable {
    public var code: String
    public var asks: [OrderBookLevel]
    public var bids: [OrderBookLevel]
    public init(code: String, asks: [OrderBookLevel], bids: [OrderBookLevel]) {
        self.code = code
        self.asks = asks
        self.bids = bids
    }
}

public struct AssetItem: Equatable, Identifiable {
    public var code: String
    public var nameKr: String
    public var holdingQty: Int
    public var purchaseAvgPrice: Double
    public var purchaseAmount: Int
    public var currentPrice: Int
    public var priceChange: Int
    public var priceChangeRate: Double
    public var evaluationAmount: Int
    public var profitLossAmount: Int
    public var profitLossRate: Double

    public var id: String { code }
    /// 일간 손익 = 전일 대비 가격 변동 × 보유 수량
    public var dailyProfitLoss: Int { priceChange * holdingQty }
    public var dailyRate: Double {
        let prev = currentPrice - priceChange
        return prev > 0 ? Double(priceChange) / Double(prev) * 100 : 0
    }
}

public struct AccountSummary: Equatable {
    public var depositAmount: Int = 0
    public var stockEvaluationAmount: Int = 0
    public var totalEvaluationAmount: Int = 0
    public var purchaseAmountTotal: Int = 0
    public var profitLossTotal: Int = 0
    public var netAssetAmount: Int = 0
    public init() {}
}

public enum OrderSide: String { case buy, sell }

public enum OrderType: String, CaseIterable, Identifiable {
    case limit = "00"
    case market = "01"
    public var id: String { rawValue }
    public var label: String { self == .limit ? "지정가" : "시장가" }
}

public struct OrderRequest {
    public var code: String
    public var side: OrderSide
    public var type: OrderType
    public var qty: Int
    public var price: Int   // 시장가는 0
    public init(code: String, side: OrderSide, type: OrderType, qty: Int, price: Int) {
        self.code = code
        self.side = side
        self.type = type
        self.qty = qty
        self.price = price
    }
}

public struct OrderResult: Equatable {
    public var orderNo: String
    public var time: String
}

public struct BuyableInfo: Equatable {
    public var maxBuyQty: Int
    public var buyableAmount: Int
}

public enum CcldFilter: String, CaseIterable, Identifiable {
    case all = "00"
    case executed = "01"
    case pending = "02"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "전체"
        case .executed: return "체결"
        case .pending: return "미체결"
        }
    }
}

public struct DailyOrderItem: Equatable, Identifiable {
    public var orderNo: String
    public var code: String
    public var nameKr: String
    public var side: OrderSide
    public var orderQty: Int
    public var orderPrice: Int
    public var execQty: Int
    public var execAvgPrice: Double
    public var execAmount: Int
    public var remainQty: Int
    public var orderTime: String
    public var status: String
    public var orderType: String

    public var id: String { "\(orderNo)-\(orderTime)-\(code)-\(orderQty)" }
}

public struct StockInfo: Codable, Equatable {
    public var nameKr: String
    public var prevPrice: Int
    public var halt: Bool
    public var designated: Bool
    public init(nameKr: String, prevPrice: Int, halt: Bool, designated: Bool) {
        self.nameKr = nameKr
        self.prevPrice = prevPrice
        self.halt = halt
        self.designated = designated
    }
}

public struct RealTimeTrade: Equatable {
    public var code: String
    public var price: Int
    public var change: Int      // 절댓값
    public var sign: String
    public var rate: Double     // 절댓값
    public var volume: Int
    public var open: Int
    public var high: Int
    public var low: Int
    public var isNxt: Bool
}

public struct OrderExecution: Equatable, Identifiable {
    public var id = UUID()
    public var code: String
    public var side: OrderSide
    public var execQty: Int
    public var execPrice: Int
    public var execTime: String
    public var orderQty: Int
}

public struct KisError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public static let notConfigured = KisError("KIS API 설정이 없습니다. 계정을 먼저 등록해 주세요.")
}

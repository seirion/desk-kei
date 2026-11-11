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

    /// 선물옵션 주문·조회에 쓰는 (종합계좌 8자리, 상품코드). 선물옵션 계좌는 같은 종합계좌의 상품코드 03 이므로
    /// 주식 계좌(01)이거나 비어 있으면 03 으로 바꾼다. 다른 상품코드(03 등)를 직접 등록했다면 그대로 쓴다.
    public var futuresAccountParts: (cano: String, product: String) {
        let p = accountParts
        return (p.cano, p.product.isEmpty || p.product == "01" ? "03" : p.product)
    }

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

    /// 앞쪽 `keep` 단계는 비어 있어도 남기고, 그 뒤쪽 단계는 가격이 있는 것만 남긴다.
    /// 거래소가 깊은 호가를 채워 주지 않으면 5호가로, 채워 주면 최대 10호가로 보이게 한다.
    public func trimmingEmptyDeepLevels(keep: Int = 5) -> OrderBook {
        func trim(_ levels: [OrderBookLevel]) -> [OrderBookLevel] {
            levels.enumerated().filter { $0.offset < keep || $0.element.price > 0 }.map(\.element)
        }
        return OrderBook(code: code, asks: trim(asks), bids: trim(bids))
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

/// 선물옵션 시세 (현재가 + 선물옵션 고유 항목)
public struct FuturesQuote: Equatable {
    public var price: KisPrice
    public var upperLimit: Int
    public var lowerLimit: Int
    /// 미결제약정 수량
    public var openInterest: Int
    /// 이론가
    public var theoreticalPrice: Int
    /// 최종거래일 yyyyMMdd
    public var lastTradeDate: String
    /// 잔존일수
    public var remainingDays: Int
}

public struct FuturesOrderRequest {
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
    /// 주문이 접수된 거래소 (KRX / NXT)
    public var exchange: String
    /// 취소된 주문 (cncl_yn)
    public var canceled = false

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
    /// 서버가 준 msg_cd (없으면 빈 문자열)
    public let code: String
    public init(_ message: String, code: String = "") {
        self.message = message
        self.code = code
    }
    public var errorDescription: String? { message }
    /// 토큰이 만료(EGW00123)되었거나 유효하지 않다(EGW00121)는 오류
    public var isTokenError: Bool { code == "EGW00123" || code == "EGW00121" }
    public static let notConfigured = KisError("KIS API 설정이 없습니다. 계정을 먼저 등록해 주세요.")
}

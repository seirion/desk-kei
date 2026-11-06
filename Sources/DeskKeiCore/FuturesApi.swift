import Foundation

/// 주식선물옵션 REST API (국내선물옵션)
extension KisClient {
    private static let quotePath = "/uapi/domestic-futureoption/v1/quotations"
    private static let tradingPath = "/uapi/domestic-futureoption/v1/trading"

    /// 선물옵션 시세. 가격은 원 단위 정수로 읽는다.
    public func futuresQuote(code: String, kind: FuturesKind) async throws -> FuturesQuote? {
        let json = try await call(path: "\(Self.quotePath)/inquire-price", trId: "FHMIF10000000", query: [
            "FID_COND_MRKT_DIV_CODE": kind.marketDivision,
            "FID_INPUT_ISCD": code,
        ])
        guard isOK(json), let o = json["output1"] as? [String: Any] else { return nil }
        return FuturesQuote(
            price: KisPrice(
                price: int(o["futs_prpr"]),
                prevPrice: int(o["futs_prdy_clpr"]),
                change: abs(int(o["futs_prdy_vrss"])),
                sign: str(o["prdy_vrss_sign"]),
                rate: abs(double(o["futs_prdy_ctrt"])),
                open: int(o["futs_oprc"]),
                high: int(o["futs_hgpr"]),
                low: int(o["futs_lwpr"]),
                volume: int(o["acml_vol"])
            ),
            upperLimit: int(o["futs_mxpr"]),
            lowerLimit: int(o["futs_llam"]),
            openInterest: int(o["hts_otst_stpl_qty"]),
            theoreticalPrice: int(o["hts_thpr"]),
            lastTradeDate: str(o["futs_last_tr_date"]),
            remainingDays: int(o["hts_rmnn_dynu"])
        )
    }

    /// 선물옵션 호가 (5호가)
    public func futuresOrderBook(code: String, kind: FuturesKind) async throws -> OrderBook? {
        let json = try await call(path: "\(Self.quotePath)/inquire-asking-price", trId: "FHMIF10010000", query: [
            "FID_COND_MRKT_DIV_CODE": kind.marketDivision,
            "FID_INPUT_ISCD": code,
        ])
        guard isOK(json), let o = json["output2"] as? [String: Any] else { return nil }
        var asks: [OrderBookLevel] = []
        var bids: [OrderBookLevel] = []
        for i in 1...5 {
            asks.append(OrderBookLevel(price: int(o["futs_askp\(i)"]), qty: int(o["askp_rsqn\(i)"])))
            bids.append(OrderBookLevel(price: int(o["futs_bidp\(i)"]), qty: int(o["bidp_rsqn\(i)"])))
        }
        return OrderBook(code: code, asks: asks, bids: bids)
    }

    /// 선물옵션 주문 (주간 TTTO1101U). 시장가는 가격 0 으로 보낸다.
    public func placeFuturesOrder(_ req: FuturesOrderRequest) async throws -> OrderResult {
        guard account.hasTradingAccount else { throw KisError.notConfigured }
        let (cano, product) = account.futuresAccountParts
        let market = req.type == .market
        let json = try await call(
            path: "\(Self.tradingPath)/order",
            method: "POST",
            trId: "TTTO1101U",
            body: [
                "ORD_PRCS_DVSN_CD": "02",
                "CANO": cano, "ACNT_PRDT_CD": product,
                "SLL_BUY_DVSN_CD": req.side == .sell ? "01" : "02",
                "SHTN_PDNO": req.code,
                "ORD_QTY": String(req.qty),
                "UNIT_PRICE": market ? "0" : String(req.price),
                "NMPR_TYPE_CD": market ? "02" : "01",
                "KRX_NMPR_CNDT_CD": "0",
                "ORD_DVSN_CD": market ? "02" : "01",
                "CTAC_TLNO": "",
                "FUOP_ITEM_DVSN_CD": "",
            ])
        try check(json, fallback: "주문 오류")
        let o = json["output"] as? [String: Any] ?? [:]
        return OrderResult(orderNo: str(o["ODNO"]), time: str(o["ORD_TMD"]))
    }
}

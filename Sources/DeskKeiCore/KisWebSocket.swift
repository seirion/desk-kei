import Foundation

/// KIS 실시간 시세 WebSocket. 끊기면 3초 후 자동 재연결하고 구독을 복원한다.
/// 모든 콜백은 메인 스레드에서 호출된다.
public final class KisWebSocket: NSObject {
    public static let url = URL(string: "ws://ops.koreainvestment.com:21000")!

    private let approvalKey: String
    private let customerId: String
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var decoder = RealtimeDecoder()
    private var wantsConnection = false
    private var reconnectWork: DispatchWorkItem?

    private var tradeCodes = Set<String>()
    private var bookCodes = Set<String>()
    private var executionKey: String?

    public var onEvent: ((RealtimeEvent) -> Void)?
    public var onStatusChange: ((Bool) -> Void)?
    /// 연결이 (재)성립된 직후 호출. 시간대가 바뀌어 tr_id 가 달라졌을 수 있어 재구독하는 용도.
    public var onConnected: (() -> Void)?

    public init(approvalKey: String, customerId: String) {
        self.approvalKey = approvalKey
        self.customerId = customerId
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    // MARK: 연결

    public func connect() {
        wantsConnection = true
        guard task == nil else { return }
        decoder = RealtimeDecoder()
        let t = session.webSocketTask(with: Self.url)
        task = t
        t.resume()
        receive(t)
    }

    public func disconnect() {
        wantsConnection = false
        reconnectWork?.cancel()
        reconnectWork = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    public var isConnected: Bool { task?.state == .running && opened }
    private var opened = false

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    if case .string(let s) = message { self.handle(s) }
                    self.receive(t)
                case .failure:
                    self.handleClosed(t)
                }
            }
        }
    }

    private func handleClosed(_ t: URLSessionWebSocketTask) {
        guard task === t else { return }
        task = nil
        opened = false
        onStatusChange?(false)
        guard wantsConnection else { return }
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func handle(_ raw: String) {
        switch decoder.decode(raw) {
        case .ping(let s): task?.send(.string(s)) { _ in }
        case .event(let e): onEvent?(e)
        case .ignored: break
        }
    }

    // MARK: 구독

    /// 체결 구독 (기존 구독은 유지)
    public func subscribeTrades(_ codes: [String]) {
        for code in codes where tradeCodes.insert(code).inserted {
            sendTrade(code, subscribe: true)
        }
    }

    public func subscribeOrderBook(_ codes: [String]) {
        for code in codes where bookCodes.insert(code).inserted {
            sendBook(code, subscribe: true)
        }
    }

    public func subscribeExecutions() {
        guard !customerId.isEmpty else { return }
        executionKey = customerId
        send(trId: "H0STCNI0", key: customerId, subscribe: true)
    }

    public func unsubscribeAll() {
        for code in tradeCodes { sendTrade(code, subscribe: false) }
        for code in bookCodes { sendBook(code, subscribe: false) }
        tradeCodes.removeAll()
        bookCodes.removeAll()
    }

    private func sendTrade(_ code: String, subscribe: Bool) {
        send(trId: MarketClock.isNxtHour() ? "H0NXCNT0" : "H0STCNT0", key: code, subscribe: subscribe)
    }

    private func sendBook(_ code: String, subscribe: Bool) {
        send(trId: MarketClock.isNxtHour() ? "H0NXASP0" : "H0STASP0", key: code, subscribe: subscribe)
    }

    private func send(trId: String, key: String, subscribe: Bool) {
        guard opened, let task else { return }
        let msg: [String: Any] = [
            "header": [
                "approval_key": approvalKey,
                "custtype": "P",
                "tr_type": subscribe ? "1" : "2",
                "content-type": "utf-8",
            ],
            "body": ["input": ["tr_id": trId, "tr_key": key]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    /// 연결 직후 기존 구독 복원
    private func restoreSubscriptions() {
        tradeCodes.forEach { sendTrade($0, subscribe: true) }
        bookCodes.forEach { sendBook($0, subscribe: true) }
        if let executionKey { send(trId: "H0STCNI0", key: executionKey, subscribe: true) }
    }
}

extension KisWebSocket: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard task === webSocketTask else { return }
        opened = true
        onStatusChange?(true)
        restoreSubscriptions()
        onConnected?()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleClosed(webSocketTask)
    }
}

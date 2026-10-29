import Foundation

/// One OpenAI Realtime transcription websocket. All callbacks run on `queue`.
/// The engine owns session logic; this class only moves JSON and reports closure once.
final class RealtimeConnection: NSObject, URLSessionWebSocketDelegate {
    static let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    let generation: Int
    let openedAt = now()
    var onEvent: (([String: Any]) -> Void)?
    /// (reason, fatal). Fatal = auth rejected; retrying won't help.
    var onClose: ((String, Bool) -> Void)?

    private let queue: DispatchQueue
    private let apiKey: String
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var lastPingAt = now()
    private var pingOutstandingSince: Double?

    init(apiKey: String, queue: DispatchQueue, generation: Int) {
        self.apiKey = apiKey
        self.queue = queue
        self.generation = generation
        super.init()
    }

    func open(sessionConfig: [String: Any]) {
        let opQueue = OperationQueue()
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: self, delegateQueue: opQueue)
        var request = URLRequest(url: Self.url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()
        send(["type": "session.update", "session": sessionConfig])
        receive()
    }

    func send(_ event: [String: Any]) {
        guard !closed, let task,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            self?.queue.async { self?.fail("send failed: \(error.localizedDescription)") }
        }
    }

    /// Call periodically. Detects dead sockets (e.g. after sleep or Wi-Fi drop).
    func keepalive() {
        guard !closed, let task else { return }
        let t = now()
        if let since = pingOutstandingSince {
            if t - since > 10 { fail("keepalive timeout") }
            return
        }
        guard t - lastPingAt > 15 else { return }
        lastPingAt = t
        pingOutstandingSince = t
        task.sendPing { [weak self] error in
            self?.queue.async {
                guard let self else { return }
                if let error { self.fail("ping failed: \(error.localizedDescription)") }
                else { self.pingOutstandingSince = nil }
            }
        }
    }

    /// Close without reporting (planned rotation / shutdown).
    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func receive() {
        task?.receive { [weak self] result in
            self?.queue.async {
                guard let self, !self.closed else { return }
                switch result {
                case .success(let message):
                    var data: Data?
                    switch message {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onEvent?(obj)
                    }
                    self.receive()
                case .failure(let error):
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        closed = true
        let status = (task?.response as? HTTPURLResponse)?.statusCode
        let fatal = status == 401 || status == 403
        let detail = status.map { "\(reason) (HTTP \($0))" } ?? reason
        task?.cancel()
        session?.invalidateAndCancel()
        onClose?(detail, fatal)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        fail("server closed the session (code \(closeCode.rawValue)) \(text)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        fail(error?.localizedDescription ?? "connection ended")
    }
}

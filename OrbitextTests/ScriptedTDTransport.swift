import Foundation
@testable import OrbitextWatch

/// JSON-level stand-in for the native TDLib client. It records every request
/// the code under test sends and answers each one from a script. No native
/// client, database or network is involved.
///
/// Inject it with `wrapper()`; `ScriptedServiceFixture` wires a real
/// `TDLibService` to one.
final class ScriptedTDTransport: @unchecked Sendable {
    enum Reply: @unchecked Sendable {
        /// Delivered as the response to the request.
        case result([String: Any])
        /// Delivered as a TDLib error object.
        case error(code: Int, message: String)
        /// Delivered after the delay, so several requests can be in flight at once.
        case delayed(TimeInterval, [String: Any])
        /// Never answered: the request stays pending until the client closes.
        case silence
    }

    typealias Script = @Sendable ([String: Any]) -> Reply

    let clientId: Int32
    private let condition = NSCondition()
    private let script: Script
    private var sent: [[String: Any]] = []
    private var responses: [String] = []
    private var closing = false
    private var outstanding: [String: Int] = [:]
    private var peakOutstanding: [String: Int] = [:]
    private var timeouts: [Double] = []
    private var timeline: [String] = []

    init(clientId: Int32 = 9100, script: @escaping Script = { _ in .result(["@type": "ok"]) }) {
        self.clientId = clientId
        self.script = script
    }

    /// Every request sent so far, in order. The `close` request is not listed.
    var requests: [[String: Any]] { condition.withLock { sent } }

    var methods: [String] { requests.compactMap { $0["@type"] as? String } }

    func requests(ofType type: String) -> [[String: Any]] {
        requests.filter { $0["@type"] as? String == type }
    }

    /// The timeout of every receive call, in order.
    var receiveTimeouts: [Double] { condition.withLock { timeouts } }

    /// "-> type" when a request is sent and "<- type" when it is answered.
    var events: [String] { condition.withLock { timeline } }

    /// The most requests of one type that were unanswered at the same moment.
    func peakInFlight(ofType type: String) -> Int {
        condition.withLock { peakOutstanding[type] ?? 0 }
    }

    /// Delivers an update TDLib sent on its own, not as the answer to a request.
    func emit(_ update: [String: Any]) {
        enqueue(update)
    }

    /// `execute` answers the synchronous requests (td_execute); by default
    /// none is answered. `requestTimeout` is what a plain `send` waits for an
    /// answer.
    func wrapper(
        execute: @escaping @Sendable (String) -> String? = { _ in nil },
        requestTimeout: Duration = .seconds(30)
    ) -> TDJsonWrapper {
        TDJsonWrapper(
            clientId: clientId,
            send: { [self] _, json in handle(json) },
            receive: { [self] timeout in nextResponse(timeout: timeout) },
            execute: execute,
            requestTimeoutNanos: UInt64(requestTimeout / .nanoseconds(1))
        )
    }

    private func handle(_ json: String) {
        guard let request = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        let type = request["@type"] as? String ?? ""
        if type == "close" {
            condition.withLock { closing = true }
            enqueue(["@type": "updateAuthorizationState",
                     "authorization_state": ["@type": "authorizationStateClosed"]])
            return
        }
        condition.withLock {
            sent.append(request)
            timeline.append("-> \(type)")
            outstanding[type, default: 0] += 1
            peakOutstanding[type] = max(peakOutstanding[type] ?? 0, outstanding[type] ?? 0)
        }
        switch script(request) {
        case .result(let object):
            deliver(answer(request, with: object))
        case .error(let code, let message):
            deliver(answer(request, with: ["@type": "error", "code": code, "message": message]))
        case .delayed(let seconds, let object):
            let answer = answer(request, with: object)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                deliver(answer)
            }
        case .silence:
            break
        }
    }

    /// A response serialized up front, so a delayed one carries only Sendable
    /// values to the queue that delivers it.
    private struct Answer: Sendable {
        let requestType: String
        let json: String
    }

    private func answer(_ request: [String: Any], with object: [String: Any]) -> Answer {
        var response = object
        response["@extra"] = request["@extra"]
        return Answer(requestType: request["@type"] as? String ?? "", json: serialized(response))
    }

    private func deliver(_ answer: Answer) {
        condition.withLock {
            outstanding[answer.requestType, default: 1] -= 1
            timeline.append("<- \(answer.requestType)")
        }
        enqueue(json: answer.json)
    }

    private func enqueue(_ object: [String: Any]) {
        enqueue(json: serialized(object))
    }

    private func serialized(_ object: [String: Any]) -> String {
        var object = object
        object["@client_id"] = clientId
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func enqueue(json: String) {
        condition.lock()
        responses.append(json)
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks like td_receive: up to `timeout` seconds for the next response.
    private func nextResponse(timeout: Double) -> String? {
        condition.lock()
        defer { condition.unlock() }
        timeouts.append(timeout)
        let deadline = Date().addingTimeInterval(timeout)
        while responses.isEmpty {
            if closing || timeout == 0 || !condition.wait(until: deadline) { return nil }
        }
        return responses.removeFirst()
    }
}

/// A real `TDLibService` whose TDLib client is a `ScriptedTDTransport`.
final class ScriptedServiceFixture: Sendable {
    let service: TDLibService
    let transport: ScriptedTDTransport
    let directory: URL
    let client: TDJsonWrapper

    init(
        downloadStallTimeout: Duration = .seconds(30),
        downloadProgressInterval: Duration = .seconds(5),
        downloadRetryDelay: Duration = .milliseconds(250),
        requestTimeout: Duration = .seconds(30),
        requestThrottle: TDRequestThrottle = TDRequestThrottle(minSpacing: .zero),
        script: @escaping ScriptedTDTransport.Script = { _ in .result(["@type": "ok"]) },
        execute: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scripted-service-\(UUID().uuidString)", isDirectory: true)
        service = TDLibService(
            databaseDirectory: directory,
            requestThrottle: requestThrottle,
            downloadStallTimeout: downloadStallTimeout,
            downloadProgressInterval: downloadProgressInterval,
            downloadRetryDelay: downloadRetryDelay
        )
        transport = ScriptedTDTransport(script: script)
        client = transport.wrapper(execute: execute, requestTimeout: requestTimeout)
        service.session.replaceClientForTesting(client)
        client.startReceiveLoop { _ in }
    }

    /// Closes the scripted client; its receive thread ends on the closed update.
    func finish() {
        service.session.replaceClientForTesting(nil)
        client.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

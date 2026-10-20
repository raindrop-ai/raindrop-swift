import Foundation
@testable import Raindrop

/// Scripted transport: records every request and answers from a per-route script.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Reply: Sendable {
        case status(Int, headers: [String: String] = [:], body: String = "")
        case error(TransportError)
        case delay(Duration, then: Int)
    }

    struct Recorded: Sendable {
        let route: String
        let host: String
        let headers: [String: String]
        let body: Data
        var json: Any { (try? JSONSerialization.jsonObject(with: body)) ?? NSNull() }
        var array: [[String: Any]] { (json as? [[String: Any]]) ?? [] }
    }

    private let lock = NSLock()
    private var scripts: [String: [Reply]] = [:]
    private var recorded: [Recorded] = []

    func script(_ route: String, _ replies: [Reply]) {
        lock.withLock { scripts[route] = replies }
    }

    /// Cloud requests only (the test endpoint is 127.0.0.1:1); Workshop mirrors are in `mirrored`.
    var requests: [Recorded] { lock.withLock { recorded.filter { $0.host == "127.0.0.1:1" } } }
    var mirrored: [Recorded] { lock.withLock { recorded.filter { $0.host != "127.0.0.1:1" } } }
    func requests(_ route: String) -> [Recorded] { requests.filter { $0.route == route } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let route = request.url.pathComponents.suffix(2).joined(separator: "/")
            .replacingOccurrences(of: "v1/", with: "")
        let reply: Reply = lock.withLock {
            recorded.append(Recorded(route: route, host: "\(request.url.host ?? ""):\(request.url.port ?? 0)", headers: request.headers, body: request.body))
            if request.url.host != "127.0.0.1" || request.url.port != 1 { return .status(200) }   // Workshop mirror
            if var queue = scripts[route], !queue.isEmpty {
                let next = queue.removeFirst()
                scripts[route] = queue
                return next
            }
            return .status(route == "events/track" ? 200 : 204)
        }
        switch reply {
        case .status(let code, let headers, let body):
            return HTTPResponse(status: code, headers: headers, body: Data(body.utf8))
        case .error(let e):
            throw e
        case .delay(let d, let code):
            try? await Task.sleep(for: d)
            return HTTPResponse(status: code)
        }
    }
}

/// Collects log lines.
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(LogLevel, String)] = []
    var warnings: [String] { lock.withLock { lines.filter { $0.0 == .warning }.map(\.1) } }
    var handler: @Sendable (LogLevel, String) -> Void {
        { [self] level, message in lock.withLock { lines.append((level, message)) } }
    }
}

func makeClient(
    _ transport: FakeTransport,
    logs: LogSink = LogSink(),
    configure: (inout RaindropConfiguration) -> Void = { _ in }
) -> RaindropClient {
    var config = RaindropConfiguration(writeKey: "test-key")
    config.endpoint = URL(string: "http://127.0.0.1:1/v1/")!
    config.transport = transport
    config.flushInterval = .seconds(3600)   // tests drive delivery explicitly
    config.logHandler = logs.handler
    config.storageDirectory = nil
    config.handleAppLifecycle = false
    configure(&config)
    return RaindropClient(configuration: config)
}

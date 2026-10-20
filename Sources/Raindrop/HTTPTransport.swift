import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var body: Data
    public var timeout: Duration
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }
}

/// Failure classes the delivery loop treats differently.
public enum TransportError: Error, Sendable, Equatable {
    /// No response within the timeout. The server may have recorded the request.
    case timedOut
    /// The connection dropped mid-request (e.g. accepted, then closed). Resent at once.
    case connectionLost
    /// Host unreachable or offline. Retried on a later cycle.
    case unreachable
    case cancelled
    case other(String)
}

/// Sends one HTTP POST. Implement this to route SDK traffic through your own stack.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Default transport: a dedicated, ephemeral `URLSession` (no cookies, no cache).
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        #if !canImport(FoundationNetworking)
        config.waitsForConnectivity = false   // fail fast offline; retried on a later cycle
        #endif
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        // URLRequest's timeout is an idle timeout: it fires when no bytes move, which is
        // exactly the hung-server case, while a slow but progressing upload continues.
        let c = request.timeout.components
        urlRequest.timeoutInterval = max(0.05, Double(c.seconds) + Double(c.attoseconds) / 1e18)
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw TransportError.connectionLost }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw TransportError.timedOut
            case .cancelled: throw TransportError.cancelled
            case .networkConnectionLost, .badServerResponse, .cannotParseResponse, .zeroByteResource:
                throw TransportError.connectionLost
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .dataNotAllowed, .internationalRoamingOff:
                throw TransportError.unreachable
            default:
                throw TransportError.other("\(error.code.rawValue)")
            }
        }
    }
}

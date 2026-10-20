import Foundation

/// Client for capture_server.py, reachable from the simulator at localhost.
struct Captured: Decodable {
    let path: String
    let status: Int
    let headers: [String: String]
    let body: String   // base64

    var data: Data { Data(base64Encoded: body) ?? Data() }
    var text: String { String(decoding: data, as: UTF8.self) }
    var json: Any? { try? JSONSerialization.jsonObject(with: data) }
    /// Route without the /v1/ prefix, e.g. "events/track"; Workshop mirrors keep a "workshop:" prefix.
    var route: String {
        if path.hasPrefix("/workshop/v1/") { return "workshop:" + path.dropFirst("/workshop/v1/".count) }
        return path.hasPrefix("/v1/") ? String(path.dropFirst(4)) : path
    }
}

enum CaptureServer {
    static let base = ProcessInfo.processInfo.environment["RD_SINK"] ?? "http://localhost:8790"

    static func requests() -> [Captured] {
        guard let data = call("GET", "/__requests") else { return [] }
        return (try? JSONDecoder().decode([Captured].self, from: data)) ?? []
    }

    static func reset() { _ = call("POST", "/__reset", body: "{}") }
    static func setMode(_ mode: String) { _ = call("POST", "/__mode", body: "{\"mode\":\"\(mode)\"}") }

    @discardableResult
    private static func call(_ method: String, _ path: String, body: String? = nil) -> Data? {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return result
    }
}

/// One decoded OTLP span.
struct OtlpSpan {
    let name: String
    let spanId: String
    let parentSpanId: String?
    let traceId: String
    let attributes: [String: String]
    let statusCode: Int

    static func all(in requests: [Captured]) -> [OtlpSpan] {
        requests.filter { $0.route == "traces" && $0.status == 200 }.flatMap { req -> [OtlpSpan] in
            guard let root = req.json as? [String: Any],
                  let resourceSpans = root["resourceSpans"] as? [[String: Any]] else { return [] }
            return resourceSpans.flatMap { rs in
                (rs["scopeSpans"] as? [[String: Any]] ?? []).flatMap { ss in
                    (ss["spans"] as? [[String: Any]] ?? []).map { s in
                        var attrs: [String: String] = [:]
                        for a in s["attributes"] as? [[String: Any]] ?? [] {
                            let v = a["value"] as? [String: Any] ?? [:]
                            attrs[a["key"] as? String ?? ""] = (v["stringValue"] as? String) ?? (v["intValue"] as? String)
                        }
                        return OtlpSpan(name: s["name"] as? String ?? "", spanId: s["spanId"] as? String ?? "",
                                        parentSpanId: s["parentSpanId"] as? String, traceId: s["traceId"] as? String ?? "",
                                        attributes: attrs,
                                        statusCode: (s["status"] as? [String: Any])?["code"] as? Int ?? 0)
                    }
                }
            }
        }
    }
}

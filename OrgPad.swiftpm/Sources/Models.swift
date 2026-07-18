import Foundation

struct Session: Codable, Equatable, Identifiable {
    let sessionID: String
    let mode: String        // "new" | "edit"
    let name: String
    let drawing: String?    // base64 PKDrawing bytes, or null for new figures
    let backgroundRaw: String?   // server-suggested export background, or nil
    var id: String { sessionID }
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"; case mode; case name; case drawing
        case backgroundRaw = "background"
    }
    var isEdit: Bool { mode == "edit" }
    var drawingData: Data? { guard let drawing else { return nil }; return Data(base64Encoded: drawing) }
}

struct PairRequest: Codable { let code: String }
struct PairResponse: Codable { let token: String }

struct ResultBody: Codable {
    let sessionID: String; let png: String; let drawing: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id"; case png; case drawing }
}
struct CancelBody: Codable {
    let sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}

enum OrgPadError: Error, Equatable {
    case badBaseURL, unauthorized, payloadTooLarge, badRequest
    case http(Int), pairingFailed(Int), noSession
}

struct OrgPadClient {
    let base: URL
    var token: String?
    static let tokenHeader = "X-OrgPad-Token"
    init?(host: String, port: Int, token: String? = nil) {
        // Build a valid URL host: drop an IPv6 zone id (e.g. %en0) and bracket
        // IPv6 literals, so a resolved IPv6 address doesn't yield a nil URL.
        var h = host
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
        if h.contains(":") && !h.hasPrefix("[") { h = "[\(h)]" }
        guard let url = URL(string: "http://\(h):\(port)") else { return nil }
        self.base = url; self.token = token
    }
    init(base: URL, token: String? = nil) { self.base = base; self.token = token }
    private func authed(_ req: inout URLRequest) {
        if let token { req.setValue(token, forHTTPHeaderField: Self.tokenHeader) }
    }
    func pairRequest(code: String) throws -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("pair"))
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(PairRequest(code: code)); return req
    }
    func sessionRequest(timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("session"))
        req.httpMethod = "GET"; req.timeoutInterval = timeout; authed(&req); return req
    }
    func resultRequest(sessionID: String, pngBase64: String, drawingBase64: String) throws -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("result"))
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ResultBody(sessionID: sessionID, png: pngBase64, drawing: drawingBase64))
        authed(&req); return req
    }
    func cancelRequest(sessionID: String) throws -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent("cancel"))
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(CancelBody(sessionID: sessionID)); authed(&req); return req
    }
}

struct Backoff {
    let base: TimeInterval; let cap: TimeInterval
    private(set) var attempt = 0
    init(base: TimeInterval = 1, cap: TimeInterval = 30) { self.base = base; self.cap = cap }
    mutating func next() -> TimeInterval {
        let delay = min(cap, base * pow(2, Double(attempt))); attempt += 1; return delay
    }
    mutating func reset() { attempt = 0 }
}

func parseManualEntry(_ raw: String, defaultPort: Int = 8777) -> (host: String, port: Int)? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if let colon = trimmed.lastIndex(of: ":") {
        let host = String(trimmed[trimmed.startIndex..<colon])
        let portStr = String(trimmed[trimmed.index(after: colon)...])
        guard !host.isEmpty, let port = Int(portStr), (1...65535).contains(port) else { return nil }
        return (host, port)
    }
    return (trimmed, defaultPort)
}

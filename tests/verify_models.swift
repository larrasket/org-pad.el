// Platform-agnostic verification of OrgPad's wire models + request building.
// Run with `swift verify_models.swift` on macOS (Foundation only, NO UIKit).
import Foundation

struct Session: Codable, Equatable {
    let sessionID: String
    let mode: String
    let name: String
    let drawing: String?
    let backgroundRaw: String?
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
struct OrgPadClient {
    let base: URL
    var token: String?
    static let tokenHeader = "X-OrgPad-Token"
    init(base: URL, token: String? = nil) { self.base = base; self.token = token }
    init?(host: String, port: Int, token: String? = nil) {
        var h = host
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
        if h.contains(":") && !h.hasPrefix("[") { h = "[\(h)]" }
        guard let url = URL(string: "http://\(h):\(port)") else { return nil }
        self.base = url; self.token = token
    }
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

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    if a != b { fatalError("FAIL: \(msg): \(a) != \(b)") }
    print("PASS: \(msg)")
}

let rawDrawing = Data([0x01, 0xDE, 0xAD, 0xBE, 0xEF])
let rawDrawingB64 = rawDrawing.base64EncodedString()
let editJSON = "{\"session_id\":\"s-42\",\"mode\":\"edit\",\"name\":\"fig\",\"drawing\":\"\(rawDrawingB64)\"}".data(using: .utf8)!
let editSession = try JSONDecoder().decode(Session.self, from: editJSON)
assertEqual(editSession.sessionID, "s-42", "session_id decode")
assertEqual(editSession.isEdit, true, "edit mode flag")
assertEqual(editSession.drawingData, rawDrawing, "base64 drawing round-trips")

let newJSON = "{\"session_id\":\"s-1\",\"mode\":\"new\",\"name\":\"fig-x\",\"drawing\":null,\"background\":\"dark\"}".data(using: .utf8)!
let newSession = try JSONDecoder().decode(Session.self, from: newJSON)
assertEqual(newSession.isEdit, false, "new mode flag")
assertEqual(newSession.drawingData == nil, true, "null drawing -> nil data")
assertEqual(newSession.backgroundRaw, "dark", "background field decodes")
// A session with no "background" key decodes backgroundRaw = nil (back-compat).
let noBgJSON = "{\"session_id\":\"s-2\",\"mode\":\"new\",\"name\":\"f\",\"drawing\":null}".data(using: .utf8)!
assertEqual(try JSONDecoder().decode(Session.self, from: noBgJSON).backgroundRaw == nil, true, "absent background -> nil")

let pairResp = try JSONDecoder().decode(PairResponse.self, from: "{\"token\":\"abc\"}".data(using: .utf8)!)
assertEqual(pairResp.token, "abc", "pair token decode")

let client = OrgPadClient(base: URL(string: "http://192.168.1.5:8777")!, token: "TOK")
let sReq = client.sessionRequest(timeout: 60)
assertEqual(sReq.url?.absoluteString, "http://192.168.1.5:8777/session", "session URL")
assertEqual(sReq.value(forHTTPHeaderField: OrgPadClient.tokenHeader), "TOK", "auth header present")
assertEqual(sReq.timeoutInterval, 60.0, "long-poll timeout")
let pReq = try client.pairRequest(code: "123456")
assertEqual(pReq.value(forHTTPHeaderField: OrgPadClient.tokenHeader) == nil, true, "pair has NO auth header")
let rReq = try client.resultRequest(sessionID: "s-42", pngBase64: "UE5H", drawingBase64: rawDrawingB64)
assertEqual(String(data: rReq.httpBody!, encoding: .utf8)!.contains("\"session_id\""), true, "result snake_case")
assertEqual(rReq.value(forHTTPHeaderField: OrgPadClient.tokenHeader), "TOK", "result authed")
let cReq = try client.cancelRequest(sessionID: "s-42")
assertEqual(String(data: cReq.httpBody!, encoding: .utf8)!.contains("\"session_id\""), true, "cancel snake_case")

var bo = Backoff(base: 1, cap: 30)
assertEqual(bo.next(), 1, "backoff 0"); assertEqual(bo.next(), 2, "backoff 1")
assertEqual(bo.next(), 4, "backoff 2"); assertEqual(bo.next(), 8, "backoff 3")
assertEqual(bo.next(), 16, "backoff 4"); assertEqual(bo.next(), 30, "backoff 5 capped")
assertEqual(bo.next(), 30, "backoff 6 stays capped"); bo.reset(); assertEqual(bo.next(), 1, "backoff reset")

assertEqual(parseManualEntry("192.168.1.5:8777")!.port, 8777, "host:port parse port")
assertEqual(parseManualEntry("mymac.tailnet.ts.net")!.port, 8777, "MagicDNS -> default port")
assertEqual(parseManualEntry("host:notaport") == nil, true, "bad port rejected")
assertEqual(parseManualEntry("  ") == nil, true, "empty rejected")

// URL host construction (IPv4 direct, IPv6 zone-stripped + bracketed)
assertEqual(OrgPadClient(host: "192.168.1.5", port: 8777)!.base.absoluteString,
            "http://192.168.1.5:8777", "IPv4 host URL")
assertEqual(OrgPadClient(host: "mymac.local", port: 8777)!.base.absoluteString,
            "http://mymac.local:8777", "hostname URL")
assertEqual(OrgPadClient(host: "fe80::1%en0", port: 8777)!.base.absoluteString,
            "http://[fe80::1]:8777", "IPv6 link-local: zone stripped + bracketed")
assertEqual(OrgPadClient(host: "2001:db8::1", port: 8777)!.base.absoluteString,
            "http://[2001:db8::1]:8777", "IPv6 global: bracketed")

print("ALL MODEL/REQUEST/BACKOFF/PARSE CHECKS PASSED")

import Foundation
import Network
import SwiftUI

@MainActor
final class ConnectionStore: ObservableObject {
    struct Discovered: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }
    @AppStorage("orgpad.host") var host: String = ""
    @AppStorage("orgpad.port") var port: Int = 8777
    @AppStorage("orgpad.token") var token: String = ""
    /// The Bonjour service name we paired with, so auto-reconnect can re-find the
    /// SAME server (by name, independent of its IP) after an IP change.
    @AppStorage("orgpad.serviceName") var serviceName: String = ""
    @Published var discovered: [Discovered] = []
    @Published var isPairing = false
    @Published var pairError: String?
    @Published var manualEntry: String = ""
    @Published var isReconnecting = false
    private var browser: NWBrowser?
    private var reconnectBrowser: NWBrowser?

    var paired: Bool { !token.isEmpty && !host.isEmpty }
    var client: OrgPadClient? {
        guard paired else { return nil }
        return OrgPadClient(host: host, port: port, token: token)
    }

    func startBrowsing() {
        stopBrowsing()
        let params = NWParameters()
        params.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_orgpad._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.discovered = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return Discovered(id: name, name: name, endpoint: result.endpoint)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() { browser?.cancel(); browser = nil }

    func resolveAndPair(_ discovered: Discovered, code: String) {
        // Remember which service we paired with so auto-reconnect can re-find it.
        serviceName = discovered.name
        // Force IPv4: the Emacs server binds 0.0.0.0 (IPv4 only), but Bonjour
        // also advertises IPv6 (often link-local fe80::…%zone) which neither
        // routes to the server nor forms a valid URL host. Constrain resolution
        // to IPv4 so we get the dotted-quad the server actually listens on.
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: discovered.endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let remote = conn.currentPath?.remoteEndpoint,
                   case let .hostPort(host: h, port: p) = remote {
                    let hostStr = Self.hostString(h)
                    conn.cancel()
                    Task { @MainActor in await self?.pair(host: hostStr, port: Int(p.rawValue), code: code) }
                } else {
                    conn.cancel()
                    Task { @MainActor in self?.pairError = "Could not resolve address." }
                }
            case .failed(let err):
                conn.cancel()
                Task { @MainActor in self?.pairError = "Resolve failed: \(err.localizedDescription)" }
            default: break
            }
        }
        conn.start(queue: .main)
    }

    private nonisolated static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let n, _): return n
        case .ipv4(let addr): return "\(addr)"
        case .ipv6(let addr): return "\(addr)"
        @unknown default: return "\(host)"
        }
    }

    func pairManual(code: String) async {
        guard let parsed = parseManualEntry(manualEntry, defaultPort: port) else {
            pairError = "Enter a valid host or host:port."
            return
        }
        await pair(host: parsed.host, port: parsed.port, code: code)
    }

    func pair(host: String, port: Int, code: String) async {
        isPairing = true; pairError = nil
        defer { isPairing = false }
        guard let client = OrgPadClient(host: host, port: port) else {
            pairError = "Invalid address."; return
        }
        do {
            let req = try client.pairRequest(code: code)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { pairError = "No response."; return }
            guard http.statusCode == 200 else {
                pairError = "Pairing rejected (\(http.statusCode)). Check the code."; return
            }
            let resp = try JSONDecoder().decode(PairResponse.self, from: data)
            self.host = host; self.port = port; self.token = resp.token
            stopBrowsing()
        } catch {
            pairError = "Pairing failed: \(error.localizedDescription)"
        }
    }

    func invalidateToken() { token = "" }

    // MARK: - Auto-reconnect (survive the server's IP changing)
    //
    // Bonjour finds the server by NAME, independent of its IP. When polling
    // starts failing (e.g. the Mac got a new DHCP lease), re-browse, find the
    // same service, resolve its CURRENT address, and update `host` — no
    // re-pairing, the token is kept. This makes the native app IP-change-proof
    // regardless of how it was originally paired.

    func rediscoverHost() {
        guard paired, reconnectBrowser == nil else { return }
        isReconnecting = true
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_orgpad._tcp", domain: nil), using: params)
        reconnectBrowser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.reconnectBrowser != nil else { return }
                // Prefer the service we paired with; else the first one found.
                let match = results.first(where: { r in
                    if case let .service(name, _, _, _) = r.endpoint { return name == self.serviceName }
                    return false
                }) ?? results.first
                guard let endpoint = match?.endpoint else { return }
                self.stopReconnectBrowsing()
                self.resolveHost(endpoint)
            }
        }
        browser.start(queue: .main)
        // Give up after a few seconds if nothing is found (stay on the old host;
        // the poll loop keeps retrying and may trigger another attempt later).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            if self.reconnectBrowser != nil { self.stopReconnectBrowsing() }
        }
    }

    private func stopReconnectBrowsing() {
        reconnectBrowser?.cancel()
        reconnectBrowser = nil
        isReconnecting = false
    }

    /// Resolve a discovered endpoint to its current host:port and update storage.
    private func resolveHost(_ endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let remote = conn.currentPath?.remoteEndpoint,
                   case let .hostPort(host: h, port: p) = remote {
                    let hostStr = Self.hostString(h)
                    let portInt = Int(p.rawValue)
                    conn.cancel()
                    Task { @MainActor in self?.host = hostStr; self?.port = portInt }
                } else {
                    conn.cancel()
                }
            case .failed:
                conn.cancel()
            default: break
            }
        }
        conn.start(queue: .main)
    }
}

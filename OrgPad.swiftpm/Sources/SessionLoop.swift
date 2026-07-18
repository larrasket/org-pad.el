import Foundation
import SwiftUI

@MainActor
final class SessionLoop: ObservableObject {
    @Published var activeSession: Session?
    @Published var isPolling = false
    @Published var lastError: String?
    private weak var connection: ConnectionStore?
    private var pollTask: Task<Void, Never>?
    private var backoff = Backoff(base: 1, cap: 30)
    private let pollTimeout: TimeInterval = 60   // > server's 55s hold

    func configure(with connection: ConnectionStore) { self.connection = connection }

    func start() {
        guard pollTask == nil else { return }
        backoff.reset()
        pollTask = Task { [weak self] in await self?.runLoop() }
    }
    func stop() { pollTask?.cancel(); pollTask = nil; isPolling = false }
    func resume() { if pollTask == nil { start() } }
    func pause() { stop() }
    func finishSession() { activeSession = nil; resume() }

    private func runLoop() async {
        while !Task.isCancelled {
            if activeSession != nil { pollTask = nil; return }
            guard let client = connection?.client else { return }
            do {
                isPolling = true
                let session = try await poll(client: client)
                isPolling = false
                backoff.reset(); lastError = nil
                if let session {
                    // Clear pollTask BEFORE returning so a later finishSession()
                    // -> resume() sees pollTask == nil and restarts polling.
                    // Without this the app goes deaf after the first drawing.
                    activeSession = session
                    pollTask = nil
                    return
                }
            } catch is CancellationError {
                return
            } catch OrgPadError.unauthorized {
                isPolling = false; connection?.invalidateToken(); return
            } catch {
                isPolling = false
                lastError = error.localizedDescription
                let delay = backoff.next()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func poll(client: OrgPadClient) async throws -> Session? {
        let req = client.sessionRequest(timeout: pollTimeout)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OrgPadError.http(-1) }
        switch http.statusCode {
        case 200: return try JSONDecoder().decode(Session.self, from: data)
        case 204: return nil
        case 401: throw OrgPadError.unauthorized
        default: throw OrgPadError.http(http.statusCode)
        }
    }
}

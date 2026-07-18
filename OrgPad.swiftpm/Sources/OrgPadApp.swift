import SwiftUI

@main
struct OrgPadApp: App {
    @StateObject private var connection = ConnectionStore()
    @StateObject private var loop = SessionLoop()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(connection)
                .environmentObject(loop)
                .onAppear { loop.configure(with: connection) }
                .onChange(of: connection.paired) { paired in
                    if paired { loop.start() } else { loop.stop() }
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active: if connection.paired { loop.resume() }
                    case .background, .inactive: loop.pause()
                    @unknown default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var connection: ConnectionStore
    @EnvironmentObject var loop: SessionLoop
    var body: some View {
        if !connection.paired {
            ConnectScreen()
        } else if let session = loop.activeSession {
            CanvasScreen(session: session).id(session.sessionID)
        } else {
            WaitingScreen()
        }
    }
}

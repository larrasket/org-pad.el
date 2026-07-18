import SwiftUI

struct WaitingScreen: View {
    @EnvironmentObject var connection: ConnectionStore
    @EnvironmentObject var loop: SessionLoop
    @State private var showUnpairConfirm = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            ConnectBackdrop().ignoresSafeArea()

            VStack(spacing: 22) {
                // Floating glass "orb" that gently breathes while idle.
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 60))
                    .foregroundStyle(.tint)
                    .padding(34)
                    .orgPadGlass(in: Circle(), interactive: false)
                    .scaleEffect(pulse ? 1.05 : 0.97)
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                               value: pulse)
                    .onAppear { pulse = true }

                VStack(spacing: 6) {
                    Text("Waiting for a drawing…")
                        .font(.title2.weight(.semibold))
                    Text("Connected to \(connection.host):\(connection.port)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if loop.isPolling {
                    Label("Listening", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .orgPadGlassCapsule()
                }

                if let err = loop.lastError {
                    Label("Reconnecting… (\(err))", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .orgPadGlassCapsule(tint: .orange)
                }

                Button(role: .destructive) { showUnpairConfirm = true } label: {
                    Label("Unpair", systemImage: "link.badge.plus")
                        .padding(.horizontal, 10).padding(.vertical, 4)
                }
                .orgPadGlassButton()
                .tint(.red)
                .padding(.top, 30)
            }
            .padding()
        }
        .confirmationDialog("Unpair this device?", isPresented: $showUnpairConfirm) {
            Button("Unpair", role: .destructive) { connection.invalidateToken() }
        }
    }
}

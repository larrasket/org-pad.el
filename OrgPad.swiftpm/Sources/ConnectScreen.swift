import SwiftUI

struct ConnectScreen: View {
    @EnvironmentObject var connection: ConnectionStore
    @State private var code = ""
    @State private var selected: ConnectionStore.Discovered?

    var body: some View {
        NavigationStack {
            ZStack {
                ConnectBackdrop().ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        header

                        glassCard {
                            sectionTitle("Discovered", systemImage: "dot.radiowaves.left.and.right")
                            if connection.discovered.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Searching for OrgPad on your network…")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ForEach(connection.discovered) { d in
                                    Button { selected = d } label: {
                                        HStack {
                                            Image(systemName: "desktopcomputer")
                                            Text(d.name)
                                            Spacer()
                                            if selected?.id == d.id {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.tint)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        glassCard {
                            sectionTitle("Or enter manually", systemImage: "keyboard")
                            TextField("host or host:port (e.g. mymac.local:8777)",
                                      text: $connection.manualEntry)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .textFieldStyle(.roundedBorder)
                        }

                        glassCard {
                            sectionTitle("Pairing code", systemImage: "number")
                            TextField("6-digit code from Emacs", text: $code)
                                .keyboardType(.numberPad)
                                .font(.system(.title2, design: .rounded).monospacedDigit())
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: code) { new in
                                    code = String(new.filter(\.isNumber).prefix(6))
                                }
                            if let err = connection.pairError {
                                Label(err, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red).font(.footnote)
                            }
                            Button { Task { await pair() } } label: {
                                Group {
                                    if connection.isPairing { ProgressView() }
                                    else { Label("Pair", systemImage: "link") }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                            }
                            .orgPadGlassProminentButton()
                            .disabled(code.count != 6 || connection.isPairing)
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding()
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Connect to OrgPad")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { connection.startBrowsing() }
            .onDisappear { connection.stopBrowsing() }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .padding(22)
                .orgPadGlass(in: Circle(), interactive: false)
            Text("Pair with Emacs")
                .font(.title2.weight(.semibold))
            Text("Run M-x org-pad-setup on your Mac, then enter the code.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func glassCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .orgPadGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func pair() async {
        if let selected { connection.resolveAndPair(selected, code: code) }
        else { await connection.pairManual(code: code) }
    }
}

/// A soft, adaptive gradient backdrop so the glass has media-rich content to
/// sample (Liquid Glass looks flat over a flat color).
struct ConnectBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.35),
                Color.blue.opacity(0.18),
                Color.purple.opacity(0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                colors: [Color.white.opacity(0.20), .clear],
                center: .topTrailing, startRadius: 20, endRadius: 520
            )
        )
    }
}

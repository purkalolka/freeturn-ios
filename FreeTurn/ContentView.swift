import SwiftUI

struct ContentView: View {
    @StateObject private var vpn = VPNController()
    @State private var logText: String = ""
    @State private var logTimer: Timer?
    @State private var captchaURL: String?
    @State private var showLog = false
    @Environment(\.openURL) private var openURL

    @AppStorage("clientId") private var clientId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    @AppStorage("freeturnLink") private var freeturnLink: String = ""
    @AppStorage("vkLink") private var vkLink: String = ""

    private var canStart: Bool {
        freeturnLink.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("freeturn://")
            && !vkLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusHeader

                    if let captcha = captchaURL, let url = URL(string: captcha) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Solve VK captcha in browser", systemImage: "safari.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }

                    field(title: "freeturn link", placeholder: "freeturn://...", text: $freeturnLink)
                    field(title: "VK call link", placeholder: "https://vk.com/call/join/...", text: $vkLink)

                    controls

                    if let err = vpn.lastError {
                        Text(err).font(.caption).foregroundColor(.red)
                    }

                    DisclosureGroup("Log", isExpanded: $showLog) { logView }
                }
                .padding()
            }
            .navigationTitle("FreeTurn")
            .onAppear { startLogPolling() }
            .onDisappear { logTimer?.invalidate() }
        }
        .navigationViewStyle(.stack)
    }

    private func startLogPolling() {
        refreshLog()
        logTimer?.invalidate()
        logTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refreshLog()
        }
    }

    private func refreshLog() {
        vpn.fetchLog()
        let fileLog = SharedLog.read()
        logText = vpn.remoteLog.isEmpty ? fileLog : vpn.remoteLog
        captchaURL = vpn.remoteCaptcha ?? SharedLog.captchaURL
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Button("Clear") { SharedLog.clear(); vpn.remoteLog = ""; refreshLog() }.font(.caption)
                Button("Refresh") { refreshLog() }.font(.caption)
            }
            ScrollView {
                Text(logText.isEmpty ? "No log yet.\n\n" + vpn.diagnostics : logText)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 300)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if vpn.active {
                Button(role: .destructive) { vpn.stop() } label: {
                    Label("Stop VPN", systemImage: "bolt.slash.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    vpn.start(freeturnLink: freeturnLink, vkLink: vkLink, clientId: clientId)
                } label: {
                    Label("Start VPN", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
        }
    }

    private func field(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)
                .disabled(vpn.active)
        }
    }

    private var statusHeader: some View {
        HStack {
            Circle()
                .fill(vpn.status == "Connected" ? Color.green : (vpn.active ? Color.orange : Color.gray))
                .frame(width: 12, height: 12)
            Text(vpn.status).font(.headline)
            Spacer()
            if vpn.active && vpn.totalStreams > 0 {
                Text("\(vpn.streams)/\(vpn.totalStreams)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(vpn.streams == vpn.totalStreams ? .secondary : .orange)
            }
        }
    }
}

#Preview {
    ContentView()
}

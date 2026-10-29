import SwiftUI

/// Camera-session chrome layered onto the shared session screen: link state,
/// offline-cache coverage, import progress, and the connection log. Culling
/// itself is the regular grid/pager.

/// One-line link + cache + import status, above the verdict counts.
struct CameraStatusRow: View {
    let camera: CameraSessionModel
    @State private var showsLog = false
    @State private var showsWiFi = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.caption.bold())
                    Text("\(camera.cachedCount)/\(camera.photos.count) cached for offline culling")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if camera.isSearching || camera.phase == .connecting {
                    ProgressView().controlSize(.small)
                } else if !camera.isConnected {
                    Button("Connect") { camera.findAndConnect() }
                        .font(.caption).buttonStyle(.bordered)
                }
                Button { showsWiFi = true } label: { Image(systemName: "wifi.router") }
                    .font(.caption)
                Button { showsLog = true } label: { Image(systemName: "text.alignleft") }
                    .font(.caption)
            }
            if let p = camera.importProgress {
                HStack(spacing: 10) {
                    // Whole-batch progress including the RAW mid-stream.
                    ProgressView(value: Double(p.done) + (camera.importWaitingForCamera ? 0 : camera.importFileFraction),
                                 total: Double(max(p.total, 1))) {
                        Text(camera.importWaitingForCamera
                             ? "Import paused — waiting for the camera (\(p.done)/\(p.total) done)"
                             : "Importing keeper \(min(p.done + 1, p.total)) of \(p.total) — full RAW")
                            .font(.caption2)
                            .foregroundStyle(camera.importWaitingForCamera ? .orange : .primary)
                    }
                    Button("Cancel") { camera.cancelImport() }.font(.caption)
                }
            } else if let summary = camera.lastImportSummary {
                Text(summary).font(.caption2).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showsWiFi) {
            // Camera Wi-Fi setup stays reachable once a session has photos.
            NavigationStack {
                VStack(spacing: 16) {
                    CameraNetworkRow(link: camera.link)
                    Button { camera.findAndConnect(); showsWiFi = false } label: {
                        Label("Connect", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(camera.isConnected || camera.isSearching)
                    Spacer()
                }
                .padding()
                .navigationTitle("Camera Wi-Fi")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showsLog) {
            NavigationStack {
                CameraLogPanel(camera: camera).padding().navigationTitle("Connection log")
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var statusColor: Color {
        switch camera.phase {
        case .connected: .green
        case .connecting: .yellow
        default: .orange
        }
    }

    private var statusTitle: String {
        if camera.isSearching { return "Looking for the camera…" }
        switch camera.phase {
        case .connected(let name): return "Connected to \(name)"
        case .connecting: return "Connecting…"
        default:
            return camera.isReconnecting ? "Offline — reconnecting, culling from cache" : "Offline — culling from cache"
        }
    }
}

/// Empty camera session: how to put the camera on Wi-Fi, one Connect button,
/// manual IP as a fallback.
struct CameraConnectPanel: View {
    @Bindable var camera: CameraSessionModel

    private var searchingTitle: String {
        if case .joining(let ssid) = camera.link.state { return "Joining \(ssid)…" }
        return "Looking for the camera…"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "camera.badge.ellipsis").font(.system(size: 44)).foregroundStyle(.secondary)
                    .padding(.top, 40)
                Text("Cull straight off your camera").font(.title3.bold())
                Text("On the camera: MENU → Network → Cnct./Remote Sht. → Remote Shooting On, with Wi-Fi Direct. Then tap Connect — the first time, pick your camera's Wi-Fi and enter the password it shows.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                if camera.isSearching {
                    ProgressView(searchingTitle)
                } else if case .connecting = camera.phase {
                    ProgressView("Connecting…")
                } else {
                    Button { camera.findAndConnect() } label: {
                        Label("Connect", systemImage: "dot.radiowaves.left.and.right")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    CameraNetworkRow(link: camera.link)
                    DisclosureGroup("Enter IP manually") {
                        HStack {
                            TextField("Camera IP", text: $camera.cameraIP)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                            Button("Connect") { camera.connect() }.buttonStyle(.bordered)
                        }
                    }
                    .font(.callout)
                    .frame(maxWidth: 300)
                }
                if case .failed(let message) = camera.phase {
                    Text(message).font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
                if !camera.logLines.isEmpty { CameraLogPanel(camera: camera).padding(.horizontal) }
            }
            .padding()
        }
    }
}

/// Live connection diagnostics — the on-device debugging surface.
struct CameraLogPanel: View {
    let camera: CameraSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connection log").font(.caption.bold())
                Spacer()
                Button("Copy") { UIPasteboard.general.string = camera.logText }.font(.caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(camera.logText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: camera.logLines.count) { proxy.scrollTo("end") }
                .onAppear { proxy.scrollTo("end") }
            }
            .frame(maxHeight: 320)
            .padding(8)
            .background(Color(white: 0.08), in: .rect(cornerRadius: 8))
        }
    }
}

/// The saved camera network (if any) with Forget, plus join status.
/// Setup itself happens inside Connect.
struct CameraNetworkRow: View {
    let link: CameraLink

    var body: some View {
        VStack(spacing: 6) {
            if let ssid = link.cameraSSID, link.hasSavedCamera {
                HStack(spacing: 8) {
                    Image(systemName: "wifi").foregroundStyle(.green)
                    Text(ssid).font(.caption).lineLimit(1)
                    Button("Forget", role: .destructive) { link.forget() }.font(.caption)
                }
            }
            switch link.state {
            case .joining(let ssid):
                ProgressView("Joining \(ssid)…").font(.caption)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            default:
                EmptyView()
            }
        }
    }
}

/// The one-time camera Wi-Fi password prompt, shown whenever Connect's
/// picker step needs it. Attach once per camera session screen.
struct CameraPasswordPrompt: ViewModifier {
    let link: CameraLink
    @State private var password = ""

    func body(content: Content) -> some View {
        content.alert("Camera Wi-Fi password", isPresented: Binding(
            get: { if case .needsPassword = link.state { true } else { false } },
            set: { if !$0, case .needsPassword = link.state { link.cancelSetup() } }
        )) {
            SecureField("Password", text: $password)
            Button("Join") { link.provide(password: password); password = "" }
            Button("Cancel", role: .cancel) { link.cancelSetup(); password = "" }
        } message: {
            if case .needsPassword(let ssid) = link.state {
                Text("Shown on the camera with its Wi-Fi Direct info. Saved in your Keychain for \(ssid) — you won't be asked again.")
            }
        }
    }
}

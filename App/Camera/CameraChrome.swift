import SwiftUI

/// Camera-session chrome layered onto the shared session screen: link state,
/// offline-cache coverage, import progress, and the connection log. Culling
/// itself is the regular grid/pager.

/// One-line link + cache + import status, above the verdict counts.
struct CameraStatusRow: View {
    let camera: CameraSessionModel
    @State private var showsLog = false

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

/// Empty camera session: how to put the camera on Wi-Fi, Find & Connect,
/// manual IP as a fallback.
struct CameraConnectPanel: View {
    @Bindable var camera: CameraSessionModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "camera.badge.ellipsis").font(.system(size: 44)).foregroundStyle(.secondary)
                    .padding(.top, 40)
                Text("Cull straight off your camera").font(.title3.bold())
                Text("On the camera: MENU → Network → Cnct./Remote Sht. → Remote Shooting On. Join the camera's Wi-Fi in Settings (or put both on the same Wi-Fi). Accept the pairing prompt on the camera the first time.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                if camera.isSearching {
                    ProgressView("Looking for the camera…")
                } else if case .connecting = camera.phase {
                    ProgressView("Connecting…")
                } else {
                    Button { camera.findAndConnect() } label: {
                        Label("Find & Connect", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    CameraWiFiSetupRow(link: camera.link)
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

/// One-tap camera Wi-Fi setup (AccessorySetupKit) or the saved network.
struct CameraWiFiSetupRow: View {
    let link: CameraLink
    @State private var password = ""

    var body: some View {
        VStack(spacing: 8) {
            if let ssid = link.cameraSSID, link.hasSavedCamera {
                HStack(spacing: 8) {
                    Image(systemName: "wifi").foregroundStyle(.green)
                    Text(ssid).font(.callout).lineLimit(1)
                    Spacer()
                    Button("Forget", role: .destructive) { link.forget() }.font(.caption)
                }
                .frame(maxWidth: 300)
            } else {
                Button { link.setUp() } label: {
                    Label("Set Up Camera Wi-Fi", systemImage: "wifi.router")
                }
                .buttonStyle(.bordered)
                Text("Pick the camera's Wi-Fi once; Vampire joins it for you after that.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
        .alert("Camera Wi-Fi password", isPresented: Binding(
            get: { if case .needsPassword = link.state { true } else { false } },
            set: { if !$0, case .needsPassword = link.state { link.cancelSetup() } }
        )) {
            SecureField("Password", text: $password)
            Button("Join") { link.provide(password: password); password = "" }
            Button("Cancel", role: .cancel) { link.cancelSetup(); password = "" }
        } message: {
            if case .needsPassword(let ssid) = link.state {
                Text("Shown on the camera with its Wi-Fi Direct info. Saved in your Keychain for \(ssid).")
            }
        }
    }
}

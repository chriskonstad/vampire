import SwiftUI

/// Camera-session chrome layered onto the shared session screen: link state,
/// offline-cache coverage, import progress, and the connection log. Culling
/// itself is the regular grid/pager.
///
/// One Connect per screen: the empty-session panel owns it; once the
/// session has photos, the status row does.

/// One-line link + cache + import status, above the verdict counts.
struct CameraStatusRow: View {
    let camera: CameraSessionModel
    /// The session's photos — known (and cached) even before the camera
    /// lists its card, e.g. culling offline after a relaunch.
    var itemIDs: [String] = []
    /// False while the empty-session panel (with its own Connect) is shown.
    var showsConnect = true
    @State private var showsLog = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.caption.bold())
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if camera.isSearching || camera.phase == .connecting {
                    ProgressView().controlSize(.small)
                } else if showsConnect, !camera.isConnected {
                    Button("Connect") { camera.findAndConnect() }
                        .font(.caption).buttonStyle(.bordered)
                }
                CameraNetworkMenu(camera: camera)
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

    private var subtitle: String {
        // The empty-session panel already shows the problem; don't repeat it.
        if showsConnect, !camera.isConnected, !camera.isSearching, let problem = camera.connectProblem { return problem }
        let ids = itemIDs.isEmpty ? camera.photos.map(\.indexID) : itemIDs
        let cached = ids.filter { camera.previewURL(forIndexID: $0) != nil }.count
        return "\(cached)/\(ids.count) cached for offline culling"
    }

    private var statusColor: Color {
        switch camera.phase {
        case .connected: .green
        case .connecting: .yellow
        default: .orange
        }
    }

    private var statusTitle: String {
        if camera.isSearching { return searchingTitle(camera) }
        switch camera.phase {
        case .connected(let name): return "Connected to \(name)"
        case .connecting: return "Connecting…"
        default:
            if camera.photos.isEmpty && itemIDs.isEmpty { return "Not connected" }
            return camera.isReconnecting ? "Offline — reconnecting, culling from cache" : "Offline — culling from cache"
        }
    }
}

/// "Joining DIRECT-…" while joining the camera's Wi-Fi, else "Looking…".
@MainActor
func searchingTitle(_ camera: CameraSessionModel) -> String {
    if case .joining(let ssid) = camera.link.state { return "Joining \(ssid)…" }
    if case .picking = camera.link.state { return "Choose your camera's Wi-Fi…" }
    return "Looking for the camera…"
}

/// Camera Wi-Fi options: the saved network, searching the current Wi-Fi
/// (camera on a shared network), forgetting the network.
struct CameraNetworkMenu: View {
    let camera: CameraSessionModel

    var body: some View {
        Menu {
            if let ssid = camera.link.cameraSSID, camera.link.hasSavedCamera {
                Section("Camera Wi-Fi") { Text(ssid) }
            }
            Button { camera.searchThisNetwork() } label: {
                Label("Search This Wi-Fi Instead", systemImage: "magnifyingglass")
            }
            if camera.link.hasSavedCamera {
                Button(role: .destructive) { camera.link.forget() } label: {
                    Label("Forget Camera Wi-Fi", systemImage: "wifi.slash")
                }
            }
        } label: {
            Image(systemName: "wifi.router")
        }
        .font(.caption)
        .disabled(camera.isSearching)
    }
}

/// Empty camera session: what to set on the camera, the one Connect, and a
/// single plain status line. The log lives in its sheet (bottom bar).
struct CameraConnectPanel: View {
    @Bindable var camera: CameraSessionModel

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
                    ProgressView(searchingTitle(camera))
                } else if case .connecting = camera.phase {
                    ProgressView("Connecting…")
                } else {
                    Button { camera.findAndConnect() } label: {
                        Label("Connect", systemImage: "dot.radiowaves.left.and.right")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if let problem = camera.connectProblem {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.orange)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }
                    CameraNetworkRow(link: camera.link)
                    Button("Camera on your home Wi-Fi? Search this network") { camera.searchThisNetwork() }
                        .font(.footnote)
                    DisclosureGroup("Enter IP manually") {
                        HStack {
                            TextField("Camera IP", text: $camera.cameraIP)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                            Button("Connect") { camera.connect() }.buttonStyle(.bordered)
                        }
                    }
                    .font(.footnote)
                    .frame(maxWidth: 300)
                }
            }
            .padding()
            .padding(.bottom, 200)  // clear of the session's bottom bar
        }
    }
}

/// The saved camera network, if any, with Forget.
struct CameraNetworkRow: View {
    let link: CameraLink

    var body: some View {
        if let ssid = link.cameraSSID, link.hasSavedCamera {
            HStack(spacing: 8) {
                Image(systemName: "wifi").foregroundStyle(.green)
                Text(ssid).font(.caption).lineLimit(1)
                Button("Forget", role: .destructive) { link.forget() }.font(.caption)
            }
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

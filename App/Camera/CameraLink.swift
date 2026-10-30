import AccessorySetupKit
import NetworkExtension
import Security
import UIKit

/// Gets the phone onto the camera's own Wi-Fi without a trip to Settings —
/// folded into Connect, so there's no separate setup step:
///
/// - First time: AccessorySetupKit's system picker finds the camera's Wi-Fi
///   Direct network, the user types the camera's Wi-Fi password once (it's
///   on the camera's screen; kept in the Keychain), and the app joins.
/// - After that: Connect rejoins the saved camera network by itself.
///
/// The picker can only filter by SSID *prefix*, and Sony puts the model
/// after a random part (`DIRECT-AbCd:ILCE-7RM5`), so `DIRECT-` also matches
/// printers and TVs. Picks that don't look like a Sony camera are rejected
/// and removed from AccessorySetupKit, with a hint on what to pick.
///
/// The picker is only used to *identify* the camera's network. Joining an
/// accessory's network is restricted to `joinAccessoryHotspot`, which
/// forces joinOnce — iOS drops a join-once network ~15s after the app
/// backgrounds or the phone sleeps, killing background imports — and a
/// persistent `NEHotspotConfiguration` for an accessory network fails with
/// "system denied configuration of the accessory network" (seen on device).
/// So once the SSID is known the accessory is released and the network is
/// joined as an ordinary saved one (iOS asks "Join …?" once; afterwards it's
/// a known network the phone rejoins on its own in the field).
///
/// Wi-Fi Aware (iOS 26) would be smoother still, but it needs accessories
/// that implement Wi-Fi Aware/NAN; current Sony bodies don't.
@MainActor
@Observable
final class CameraLink {
    enum State: Equatable {
        case idle
        case picking
        case needsPassword(ssid: String)
        case joining(ssid: String)
        case joined(ssid: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The camera network chosen in the picker (persisted).
    private(set) var cameraSSID: String? = UserDefaults.standard.string(forKey: "camera.ssid") {
        didSet { UserDefaults.standard.set(cameraSSID, forKey: "camera.ssid") }
    }

    @ObservationIgnored private var session: ASAccessorySession?
    @ObservationIgnored private var activation: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isActivated = false
    /// Resumed when the current pick-and-join attempt ends (true = joined).
    @ObservationIgnored private var pending: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
        // An earlier build accepted any DIRECT- network (a printer, say).
        if let ssid = cameraSSID, !Self.isSonyCamera(ssid: ssid) { forget() }
    }

    var hasSavedCamera: Bool { cameraSSID != nil && cameraSSID.flatMap(Keychain.password(for:)) != nil }

    /// Sony Wi-Fi Direct networks: `DIRECT-<random>:<model>` with a Sony
    /// model family — ILCE (α), ILME (Cinema Line), ZV, DSC (RX), ILX.
    /// Lenient about the separator; printers/TVs never carry these models.
    static func isSonyCamera(ssid: String) -> Bool {
        ssid.range(of: #"^DIRECT-.+(ILCE|ILME|ZV|DSC|ILX)-"#, options: .regularExpression) != nil
    }

    // MARK: - Connect support

    /// If a camera network is saved and the phone isn't on it, joins it.
    /// Returns true when the phone is (now) on the camera's network.
    func joinSavedCameraIfNeeded() async -> Bool {
        guard let ssid = cameraSSID, let password = Keychain.password(for: ssid) else { return false }
        if await Self.currentSSID() == ssid { return true }
        log("joining saved camera Wi-Fi \(ssid)")
        return await join(ssid: ssid, password: password)
    }

    /// The picker → password → join flow, in one await. Must start from a
    /// user action. Returns true once joined; false if cancelled or failed.
    func pickAndJoin() async -> Bool {
        if let pending { pending.resume(returning: false) }
        return await withCheckedContinuation { cont in
            pending = cont
            state = .picking
            Task { await self.presentPicker() }
        }
    }

    /// The password from the camera's Wi-Fi info screen, entered once.
    func provide(password: String) {
        guard case .needsPassword(let ssid) = state else { return }
        Keychain.setPassword(password, for: ssid)
        Task {
            let ok = await join(ssid: ssid, password: password)
            resolve(ok)
        }
    }

    func cancelSetup() {
        state = .idle
        resolve(false)
    }

    /// Forgets the saved camera network (and its AccessorySetupKit entry).
    func forget() {
        if let ssid = cameraSSID {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            Keychain.deletePassword(for: ssid)
        }
        cameraSSID = nil
        state = .idle
        releaseAccessories()
    }

    /// Drops every AccessorySetupKit accessory so the camera network is an
    /// ordinary one we may configure persistently.
    private func releaseAccessories() {
        for accessory in session?.accessories ?? [] {
            session?.removeAccessory(accessory) { _ in }
        }
    }

    private func resolve(_ ok: Bool) {
        let cont = pending
        pending = nil
        cont?.resume(returning: ok)
    }

    // MARK: - AccessorySetupKit

    private func activatedSession() async -> ASAccessorySession {
        if let session, isActivated { return session }
        let session = self.session ?? ASAccessorySession()
        if self.session == nil {
            self.session = session
            session.activate(on: .main) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        await withCheckedContinuation { activation.append($0) }
        return session
    }

    private func presentPicker() async {
        let session = await activatedSession()
        // Already registered from an earlier pick: use it, no picker (and
        // no removal — each removal is a system confirmation).
        if let known = session.accessories.first(where: { ($0.ssid).map(Self.isSonyCamera(ssid:)) ?? false }),
           let ssid = known.ssid {
            accessoryChosen(known, ssid: ssid)
            return
        }
        let descriptor = ASDiscoveryDescriptor()
        if let known = cameraSSID {
            descriptor.ssid = known        // exact: no printers in the list
        } else {
            descriptor.ssidPrefix = "DIRECT-"  // narrowed to Sony after the pick
        }
        let item = ASPickerDisplayItem(name: "Sony camera Wi-Fi", productImage: Self.productImage, descriptor: descriptor)
        session.showPicker(for: [item]) { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.log("camera picker failed: \(error.localizedDescription)")
                self?.state = .failed("Couldn't show the camera picker: \(error.localizedDescription)")
                self?.resolve(false)
            }
        }
    }

    /// A Sony camera network was identified. Release the accessory once —
    /// iOS only lets an accessory's network be joined join-once, which
    /// background imports can't survive — then join it as a plain saved
    /// network. (This is the one system confirmation in setup.)
    private func accessoryChosen(_ accessory: ASAccessory, ssid: String) {
        log("camera Wi-Fi identified: \(ssid)")
        cameraSSID = ssid
        session?.removeAccessory(accessory) { _ in }
        if let password = Keychain.password(for: ssid) {
            Task { resolve(await join(ssid: ssid, password: password)) }
        } else {
            state = .needsPassword(ssid: ssid)
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            isActivated = true
            activation.forEach { $0.resume() }
            activation.removeAll()
        case .accessoryAdded, .accessoryChanged:
            guard let accessory = event.accessory, let ssid = accessory.ssid else { return }
            guard Self.isSonyCamera(ssid: ssid) else {
                log("picked \(ssid) — not a Sony camera, ignoring")
                session?.removeAccessory(accessory) { _ in }
                state = .failed("“\(ssid)” isn't a Sony camera. Turn on the camera's Wi-Fi Direct and pick the network ending in its model, like “:ILCE-7RM5”.")
                resolve(false)
                return
            }
            accessoryChosen(accessory, ssid: ssid)
        case .pickerDidDismiss:
            if state == .picking { state = .idle; resolve(false) }
        case .invalidated:
            session = nil
            isActivated = false
            if state == .picking { state = .idle; resolve(false) }
        default:
            break
        }
    }

    private static var productImage: UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 120, weight: .regular)
        return UIImage(systemName: "camera.fill", withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) ?? UIImage()
    }

    // MARK: - Joining

    private func join(ssid: String, password: String) async -> Bool {
        state = .joining(ssid: ssid)
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = false  // stay joined in the background / when locked
        let error = await withCheckedContinuation { (cont: CheckedContinuation<NSError?, Never>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { cont.resume(returning: $0 as NSError?) }
        }
        if let error, !(error.domain == NEHotspotConfigurationErrorDomain
                         && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
            log("joining \(ssid) failed: \(error.localizedDescription)")
            let code = error.domain == NEHotspotConfigurationErrorDomain
                ? NEHotspotConfigurationError(rawValue: error.code) : nil
            switch code {
            case .invalidWPAPassphrase?:
                Keychain.deletePassword(for: ssid)
                state = .failed("The camera's Wi-Fi password didn't work. Tap Connect to enter it again.")
            case .systemDenied?:
                state = .failed("iOS wouldn't join the camera's Wi-Fi. Tap Connect to try again.")
            case .userDenied?:
                state = .failed("Joining the camera's Wi-Fi was declined.")
            default:
                state = .failed("Couldn't join the camera's Wi-Fi. Is the camera on, with Wi-Fi Direct?")
            }
            return false
        }
        // apply() returns before association + DHCP finish: wait until the
        // phone is really on the camera's network (no fixed sleep).
        for _ in 0 ..< 40 where await Self.currentSSID() != ssid {
            try? await Task.sleep(for: .milliseconds(500))
        }
        log("joined camera Wi-Fi \(ssid)")
        state = .joined(ssid: ssid)
        return true
    }

    /// The current Wi-Fi's SSID — readable because this app configured the
    /// camera network (Hotspot Configuration entitlement).
    static func currentSSID() async -> String? {
        await withCheckedContinuation { cont in
            NEHotspotNetwork.fetchCurrent { cont.resume(returning: $0?.ssid) }
        }
    }
}

/// Minimal Keychain storage for camera Wi-Fi passwords.
enum Keychain {
    private static let service = "com.chriskonstad.vampire.camera-wifi"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for account: String) {
        deletePassword(for: account)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                   kSecValueData as String: Data(password.utf8)]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deletePassword(for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

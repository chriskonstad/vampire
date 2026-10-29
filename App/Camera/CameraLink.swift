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
/// Joins use a persistent `NEHotspotConfiguration`, not
/// `joinAccessoryHotspot`: the latter forces joinOnce, and iOS drops a
/// join-once network ~15s after the app backgrounds or the phone sleeps,
/// which would kill background imports. (Persistent joins need the Hotspot
/// Configuration entitlement; because the network was chosen in the
/// AccessorySetupKit picker, iOS skips its own "join network?" prompt.)
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
        // A previously picked accessory suppresses re-discovery; clear any
        // that isn't the saved camera (e.g. a wrongly picked printer).
        for accessory in session.accessories where accessory.ssid != cameraSSID {
            session.removeAccessory(accessory) { _ in }
        }
        let descriptor = ASDiscoveryDescriptor()
        descriptor.ssidPrefix = "DIRECT-"  // narrowed to Sony after the pick
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
            log("camera Wi-Fi chosen: \(ssid)")
            cameraSSID = ssid
            if let password = Keychain.password(for: ssid) {
                Task { resolve(await join(ssid: ssid, password: password)) }
            } else {
                state = .needsPassword(ssid: ssid)
            }
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
            if error.domain == NEHotspotConfigurationErrorDomain,
               error.code == NEHotspotConfigurationError.invalidWPAPassphrase.rawValue {
                Keychain.deletePassword(for: ssid)
            }
            state = .failed("Couldn't join \(ssid): \(error.localizedDescription)")
            return false
        }
        log("joined camera Wi-Fi \(ssid)")
        state = .joined(ssid: ssid)
        try? await Task.sleep(for: .seconds(3))  // association + DHCP
        return true
    }

    /// The current Wi-Fi's SSID — readable because this app configured the
    /// camera network (Hotspot Configuration entitlement).
    private static func currentSSID() async -> String? {
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

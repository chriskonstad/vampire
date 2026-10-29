import AccessorySetupKit
import NetworkExtension
import Security
import UIKit

/// The smoothest way onto the camera's own Wi-Fi, without a trip to
/// Settings: AccessorySetupKit's system picker discovers the camera's Wi-Fi
/// Direct network (`DIRECT-…`, e.g. `DIRECT-AbCd:ILCE-7RM5`), the user types
/// the camera's Wi-Fi password once (shown on the camera; kept in the
/// Keychain), and the app joins it with a persistent hotspot configuration.
/// Afterwards `joinIfConfigured()` rejoins on its own when the camera isn't
/// reachable on the current network.
///
/// Why not `joinAccessoryHotspot`: it always sets joinOnce, and iOS drops a
/// join-once network ~15s after the app backgrounds or the phone sleeps —
/// which would kill background imports. A persistent configuration needs
/// the Hotspot Configuration entitlement; because the network was chosen in
/// the AccessorySetupKit picker, iOS skips its own "join network?" prompt.
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
    @ObservationIgnored private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    var hasSavedCamera: Bool { cameraSSID != nil && cameraSSID.flatMap(Keychain.password(for:)) != nil }

    // MARK: - Set up (AccessorySetupKit picker)

    /// Shows the system accessory picker for camera Wi-Fi Direct networks.
    /// Call from a user action.
    func setUp() {
        state = .picking
        let session = ASAccessorySession()
        self.session = session
        session.activate(on: .main) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            showPicker()
        case .accessoryAdded, .accessoryChanged:
            guard let ssid = event.accessory?.ssid else { return }
            log("camera Wi-Fi chosen: \(ssid)")
            cameraSSID = ssid
            if let password = Keychain.password(for: ssid) {
                join(ssid: ssid, password: password)
            } else {
                state = .needsPassword(ssid: ssid)
            }
        case .pickerDidDismiss:
            if state == .picking { state = .idle }
        case .invalidated:
            session = nil
            if state == .picking { state = .idle }
        default:
            break
        }
    }

    private func showPicker() {
        let descriptor = ASDiscoveryDescriptor()
        // Sony's Wi-Fi Direct networks are "DIRECT-xxxx:<model>". (The
        // prefix also matches other Wi-Fi Direct gear; the picker shows the
        // network names so the user picks the camera.)
        descriptor.ssidPrefix = "DIRECT-"
        let item = ASPickerDisplayItem(name: "Sony camera", productImage: Self.productImage, descriptor: descriptor)
        session?.showPicker(for: [item]) { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.log("camera picker failed: \(error.localizedDescription)")
                self?.state = .failed("Couldn't show the camera picker: \(error.localizedDescription)")
            }
        }
    }

    private static var productImage: UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 120, weight: .regular)
        return UIImage(systemName: "camera.fill", withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) ?? UIImage()
    }

    // MARK: - Join

    /// The password from the camera's Wi-Fi info screen, entered once.
    func provide(password: String) {
        guard case .needsPassword(let ssid) = state else { return }
        Keychain.setPassword(password, for: ssid)
        join(ssid: ssid, password: password)
    }

    func cancelSetup() {
        state = .idle
    }

    /// Rejoins the saved camera network (no-op without one). Returns once
    /// iOS reports the join result.
    @discardableResult
    func joinIfConfigured() async -> Bool {
        guard let ssid = cameraSSID, let password = Keychain.password(for: ssid) else { return false }
        return await withCheckedContinuation { cont in
            join(ssid: ssid, password: password) { cont.resume(returning: $0) }
        }
    }

    private func join(ssid: String, password: String, completion: ((Bool) -> Void)? = nil) {
        state = .joining(ssid: ssid)
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = false  // stay joined in the background / when locked
        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error = error as NSError?,
                   !(error.domain == NEHotspotConfigurationErrorDomain
                     && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
                    self.log("joining \(ssid) failed: \(error.localizedDescription)")
                    if error.domain == NEHotspotConfigurationErrorDomain,
                       error.code == NEHotspotConfigurationError.invalidWPAPassphrase.rawValue {
                        Keychain.deletePassword(for: ssid)
                    }
                    self.state = .failed("Couldn't join \(ssid): \(error.localizedDescription)")
                    completion?(false)
                } else {
                    self.log("joined camera Wi-Fi \(ssid)")
                    self.state = .joined(ssid: ssid)
                    completion?(true)
                }
            }
        }
    }

    /// Forgets the saved camera network and its password.
    func forget() {
        if let ssid = cameraSSID {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            Keychain.deletePassword(for: ssid)
        }
        cameraSSID = nil
        state = .idle
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

import Foundation
import Network

/// Finds the camera on the current Wi-Fi without the user typing an IP:
/// probes the PTP/IP port (15740). Plain unicast TCP, so it needs only the
/// Local Network permission — no multicast entitlement (which SSDP discovery
/// would require).
///
/// Order matters for speed: the last address that worked (on any network),
/// then the Wi-Fi path's real gateway as iOS reports it (on the camera's own
/// Wi-Fi Direct network the camera *is* the gateway), then the gateway's /24
/// in parallel batches.
///
/// The network comes from `NWPathMonitor`, not from guessing en0's address
/// with getifaddrs: on device that reported the home 192.168.0.x address
/// while the phone was on the camera's network, so the finder scanned the
/// wrong subnet and never tried the camera.
enum CameraFinder {
    static func find(preferred: String?, port: UInt16 = 15740,
                     log: @Sendable (String) -> Void = { _ in }) async -> String? {
        let gateways = await wifiGateways()
        let interfaces = ipv4Interfaces()
        log("finder: Wi-Fi gateways [\(gateways.joined(separator: ", "))], "
            + "interfaces [\(interfaces.map { "\($0.name) \(format($0.address))" }.joined(separator: ", "))]")

        var solo: [String] = []
        if let preferred, parse(preferred) != nil { solo.append(preferred) }
        for gateway in gateways where !solo.contains(gateway) { solo.append(gateway) }
        for host in solo {
            if await isOpen(host, port: port, timeout: 2.5) { return host }
            log("finder: \(host) not answering")
        }

        // Sweep the gateway's /24; fall back to the Wi-Fi interface's own.
        let wifiAddress = interfaces.first { $0.name == "en0" }
        guard let base = gateways.first.flatMap(parse).map({ $0 & 0xFFFF_FF00 })
                ?? wifiAddress.map({ $0.address & max($0.mask, 0xFFFF_FF00) }) else {
            log("finder: no Wi-Fi network to scan")
            return nil
        }
        log("finder: scanning \(format(base))/24")
        let own = Set(interfaces.map(\.address))
        let hosts = (1 ..< 255).map { base | $0 }
            .filter { !own.contains($0) }
            .map(format)
            .filter { !solo.contains($0) }
        for batch in stride(from: 0, to: hosts.count, by: 48) {
            let slice = hosts[batch ..< min(batch + 48, hosts.count)]
            let found = await withTaskGroup(of: String?.self) { group -> String? in
                for host in slice { group.addTask { await isOpen(host, port: port, timeout: 1.5) ? host : nil } }
                for await result in group where result != nil {
                    group.cancelAll()
                    return result
                }
                return nil
            }
            if let found { return found }
        }
        return nil
    }

    /// IPv4 gateways of the current Wi-Fi path, straight from iOS.
    private static func wifiGateways() async -> [String] {
        await withCheckedContinuation { cont in
            #if targetEnvironment(simulator)
            let monitor = NWPathMonitor()
            #else
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            #endif
            let once = FinderOnce()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                let gateways = path.gateways.compactMap { endpoint -> String? in
                    guard case .hostPort(.ipv4(let address), _) = endpoint else { return nil }
                    // Drop any "%en0" scope suffix.
                    return "\(address)".split(separator: "%").first.map(String.init)
                }
                cont.resume(returning: gateways)
            }
            monitor.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if once.claim() { monitor.cancel(); cont.resume(returning: []) }
            }
        }
    }

    /// Quick single-host check (e.g. the last camera address on this Wi-Fi).
    static func probe(_ host: String, port: UInt16 = 15740, timeout: Double = 1.5) async -> Bool {
        await isOpen(host, port: port, timeout: timeout)
    }

    /// TCP connect test to the PTP/IP port, pinned to Wi-Fi.
    private static func isOpen(_ host: String, port: UInt16, timeout: Double) async -> Bool {
        let params = NWParameters.tcp
        #if !targetEnvironment(simulator)
        params.requiredInterfaceType = .wifi  // the simulator's network isn't typed Wi-Fi
        #endif
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        return await withCheckedContinuation { cont in
            let once = FinderOnce()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { conn.cancel(); cont.resume(returning: true) }
                case .failed, .cancelled:
                    if once.claim() { conn.cancel(); cont.resume(returning: false) }
                case .waiting:
                    // Not a "no": a Wi-Fi-pinned connection often reports
                    // waiting("Network is down") for a beat before going
                    // ready. Treating it as absent made the scan skip the
                    // camera itself. Let the timeout decide.
                    break
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { conn.cancel(); cont.resume(returning: false) }
            }
        }
    }

    /// Every up IPv4 interface (host byte order), for logging and fallback.
    private static func ipv4Interfaces() -> [(name: String, address: UInt32, mask: UInt32)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [(name: String, address: UInt32, mask: UInt32)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if a >> 24 == 127 || a >> 16 == 0xA9FE { continue }  // loopback, link-local
            out.append((String(cString: ifa.ifa_name), a, m))
        }
        return out
    }

    private static func format(_ ip: UInt32) -> String {
        "\(ip >> 24).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
    }

    private static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts.reduce(0) { $0 << 8 | $1 }
    }
}

private final class FinderOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

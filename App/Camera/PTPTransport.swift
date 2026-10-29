import Foundation
import Network

import PTP

/// PTP/IP transport over the camera's Wi-Fi: opens the command and event TCP
/// channels, performs the init handshake, and runs operations by driving the
/// tested `PTP` codec. One actor, serialized access — PTP is a strict
/// request/response protocol and must not interleave transactions.
///
/// Live socket behavior (Sony's handshake quirks, data-phase pacing, which
/// modes expose browsing) is verified against the real A7RV; every step is
/// reported through `log` so on-device failures are diagnosable. Cannot run in
/// the simulator. `tools/ptpip_probe.py` is the Mac-side twin of this flow.
actor PTPTransport {
    enum TransportError: Error, CustomStringConvertible {
        case notConnected
        case connectionFailed(String)
        case unexpectedPacket(PTPIPPacketType)
        case operationFailed(PTPOperation, UInt16)
        case timeout

        /// True when the link itself is gone (vs. the camera refusing one
        /// operation, after which the session is still fine).
        var isConnectionLoss: Bool {
            if case .operationFailed = self { false } else { true }
        }

        var description: String {
            switch self {
            case .notConnected: "not connected"
            case .connectionFailed(let why): "connection failed: \(why)"
            case .unexpectedPacket(let type): "unexpected packet \(type)"
            case .operationFailed(let op, let code):
                "\(op) failed: 0x\(String(code, radix: 16, uppercase: true))"
                    + (PTPResponse(rawValue: code).map { " (\($0))" } ?? "")
            case .timeout: "timed out"
            }
        }
    }

    typealias Log = @Sendable (String) -> Void

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let log: Log
    private var command: Channel?
    private var event: Channel?
    private var nextTransactionID: UInt32 = 1
    /// Stable per-install GUID for the PTP handshake.
    private let guid: Data
    /// Fires once when the link dies on its own (camera off, out of range,
    /// keepalive failure) — not on `close()`. Idle sessions have no other
    /// way to notice: a powered-off camera never closes its sockets.
    private let onDisconnect: @Sendable () -> Void
    private var isClosing = false

    init(host: String, port: UInt16 = 15740, guid: Data, log: @escaping Log,
         onDisconnect: @escaping @Sendable () -> Void = {}) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.guid = guid
        self.log = log
        self.onDisconnect = onDisconnect
    }

    // MARK: - Connect

    func connect(hostName: String = "Vampire") async throws -> PTPHandshake.CommandAck {
        log("TCP → \(host):\(port) (command)")
        let command = Channel(try await open())
        self.command = command
        try await command.send(PTPHandshake.initCommandRequest(guid: guid, hostName: hostName))
        let reply = try await command.readPacket()
        guard reply.type == .initCommandAck else {
            log("← \(reply.type) \(reply.payload.prefix(8).hexString)")
            if reply.type == .initFail {
                throw TransportError.connectionFailed("camera refused init — accept the connection on the camera, or check Access Auth.")
            }
            throw TransportError.unexpectedPacket(reply.type)
        }
        let ack = try PTPHandshake.parseCommandAck(reply)
        log("← InitCommandAck conn#\(ack.connectionNumber) “\(ack.cameraName)”")

        // The spec requires the event channel before any operation; cameras
        // typically ignore OpenSession until it exists.
        log("TCP → \(host):\(port) (event)")
        let event = Channel(try await open())
        self.event = event
        try await event.send(PTPHandshake.initEventRequest(connectionNumber: ack.connectionNumber))
        let eventReply = try await event.readPacket()
        guard eventReply.type == .initEventAck else {
            log("← event \(eventReply.type) \(eventReply.payload.prefix(8).hexString)")
            throw TransportError.unexpectedPacket(eventReply.type)
        }
        log("← InitEventAck")
        Task { [log] in
            // Drain camera events so its send buffer never stalls. The camera
            // also pings here (~20s); an unanswered ping gets the session
            // dropped. Property-changed (0xC203) chatter isn't worth logging.
            // With TCP keepalive on, this read fails within ~10s of the camera
            // going dark — the idle-session disconnect signal.
            do {
                while true {
                    let packet = try await event.readPacket()
                    switch packet.type {
                    case .probeRequest:
                        try await event.send(PTPIPPacket(type: .probeResponse, payload: Data()))
                    case .event where packet.payload.starts(with: [0x03, 0xC2]):
                        continue
                    default:
                        log("event \(packet.type) \(packet.payload.prefix(10).hexString)")
                    }
                }
            } catch {
                await self.eventChannelEnded(error)
            }
        }
        return ack
    }

    private func eventChannelEnded(_ error: Error) async {
        guard !isClosing else { return }
        log("link lost: \(error)")
        await close()
        onDisconnect()
    }

    func close() async {
        isClosing = true
        await command?.cancel()
        await event?.cancel()
        command = nil
        event = nil
    }

    // MARK: - Operations

    /// Runs one PTP operation and returns its raw response code plus any
    /// data-phase payload (nil for no-data operations).
    @discardableResult
    func perform(_ operation: PTPOperation, parameters: [UInt32] = []) async throws
        -> (code: UInt16, data: Data?) {
        // Actors re-enter at every await, so without this two callers
        // (prefetch + import) would interleave transactions on the wire.
        await acquire()
        defer { release() }
        guard let command else { throw TransportError.notConnected }
        // Watchdog: a vanished camera can leave TCP hanging for minutes. Any
        // silence over 15s kills the channel so callers fail fast to offline.
        let watchdog = Task { [log] in
            while true {
                try await Task.sleep(for: .seconds(5))
                if await command.secondsSinceLastActivity > 15 {
                    log("\(operation): no response for 15s — dropping connection")
                    await command.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        let tid = nextTransactionID
        nextTransactionID &+= 1
        try await command.send(PTPOperationRequest(operation, transactionID: tid, parameters: parameters).packet())

        var assembler = PTPDataPhaseAssembler(transactionID: tid)
        while true {
            let packet = try await command.readPacket()
            switch packet.type {
            case .startData, .data, .endData:
                _ = try assembler.accept(packet)
            case .operationResponse:
                let code = packet.payload.count >= 2
                    ? UInt16(packet.payload[packet.payload.startIndex])
                        | UInt16(packet.payload[packet.payload.startIndex + 1]) << 8
                    : 0
                let data = assembler.isComplete ? assembler.data : nil
                if code != PTPResponse.ok.rawValue || operation != .getObjectInfo {
                    log("\(operation) \(parameters.map { String($0, radix: 16) }) → "
                        + "0x\(String(code, radix: 16, uppercase: true)) \(data.map { "\($0.count)B" } ?? "")")
                }
                return (code, data)
            case .probeRequest:
                try await command.send(PTPIPPacket(type: .probeResponse, payload: Data()))
            case .event, .probeResponse:
                continue
            default:
                throw TransportError.unexpectedPacket(packet.type)
            }
        }
    }

    /// Like `perform`, but throws unless the response was OK and (for data-in
    /// ops) a complete, non-short payload arrived.
    ///
    /// DeviceBusy is retried with backoff: Sony bodies answer it routinely
    /// mid-session (seen on the A7RV during back-to-back screennail pulls),
    /// and every op we send is a side-effect-free read, so retry is safe.
    func require(_ operation: PTPOperation, parameters: [UInt32] = [],
                 expectsData: Bool = false) async throws -> Data {
        var (code, data) = try await perform(operation, parameters: parameters)
        var delay: Duration = .milliseconds(100)
        var attempts = 0
        while code == PTPResponse.deviceBusy.rawValue, attempts < 8 {
            attempts += 1
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(1))
            (code, data) = try await perform(operation, parameters: parameters)
        }
        guard code == PTPResponse.ok.rawValue else { throw TransportError.operationFailed(operation, code) }
        if expectsData {
            guard let data else {
                throw TransportError.operationFailed(operation, PTPResponse.incompleteTransfer.rawValue)
            }
            return data
        }
        return data ?? Data()
    }

    // MARK: - Transaction lock (FIFO)

    private var inTransaction = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !inTransaction { inTransaction = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { inTransaction = false } else { waiters.removeFirst().resume() }
    }

    // MARK: - Socket plumbing

    private func open() async throws -> NWConnection {
        // Keepalive: probe after 3s idle, every 2s, give up after 3 misses —
        // a camera switched off is noticed in ~10s instead of never.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 3
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: nil, tcp: tcp)
        // Pin to Wi-Fi: the camera's AP has no internet, so without this iOS
        // may route the socket over cellular and never reach the camera.
        #if !targetEnvironment(simulator)
        params.requiredInterfaceType = .wifi  // the simulator's network isn't typed Wi-Fi
        #endif
        let conn = NWConnection(host: host, port: port, using: params)
        let log = self.log
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume() }
                case .failed(let err):
                    if once.claim() { cont.resume(throwing: TransportError.connectionFailed("\(err)")) }
                case .waiting(let err):
                    // First run sits here while the Local Network prompt is
                    // up, so waiting usually isn't fatal — but "refused" is a
                    // definite no (camera off / remote shooting off): fail
                    // now so reconnect loops retry quickly instead of
                    // sitting out the timeout.
                    log("TCP waiting: \(err)")
                    if case .posix(.ECONNREFUSED) = err, once.claim() {
                        conn.cancel()
                        cont.resume(throwing: TransportError.connectionFailed("\(err)"))
                    }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: TransportError.notConnected) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                if once.claim() {
                    conn.cancel()
                    cont.resume(throwing: TransportError.timeout)
                }
            }
        }
        return conn
    }

    /// One TCP channel with its own receive buffer.
    actor Channel {
        private let conn: NWConnection
        private var buffer = Data()
        private var lastActivity = ContinuousClock.now

        var secondsSinceLastActivity: Double {
            let d = ContinuousClock.now - lastActivity
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }

        /// The in-flight receive, so `cancel()` can wake it. NWConnection
        /// doesn't promise to complete a pending receive on cancel, and a
        /// read that never returns wedges the transaction lock (the stuck
        /// "Importing 0/3" bug).
        private var pending: (once: OnceFlag, cont: CheckedContinuation<Data, Error>)?
        private var isCancelled = false

        init(_ conn: NWConnection) {
            self.conn = conn
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    Task { await self?.cancel() }
                default:
                    break
                }
            }
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            conn.cancel()
            if let pending, pending.once.claim() {
                pending.cont.resume(throwing: TransportError.notConnected)
            }
            pending = nil
        }

        func send(_ packet: PTPIPPacket) async throws {
            lastActivity = .now
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.send(content: packet.encoded(), completion: .contentProcessed { err in
                    if let err { cont.resume(throwing: TransportError.connectionFailed("\(err)")) }
                    else { cont.resume() }
                })
            }
        }

        /// Returns the next complete PTP/IP packet, reading until one is
        /// fully buffered.
        func readPacket() async throws -> PTPIPPacket {
            while true {
                if let (packet, consumed) = try PTPIPPacket.parse(buffer) {
                    buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + consumed)
                    return packet
                }
                guard !isCancelled else { throw TransportError.notConnected }
                let chunk: Data = try await withCheckedThrowingContinuation { cont in
                    let once = OnceFlag()
                    pending = (once, cont)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, err in
                        guard once.claim() else { return }
                        if let err { cont.resume(throwing: TransportError.connectionFailed("\(err)")); return }
                        if let data, !data.isEmpty { cont.resume(returning: data); return }
                        if isComplete { cont.resume(throwing: TransportError.notConnected); return }
                        cont.resume(returning: Data())
                    }
                }
                pending = nil
                buffer.append(chunk)
                lastActivity = .now
            }
        }
    }
}

/// Thread-safe "first caller wins" flag for one-shot continuations.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}

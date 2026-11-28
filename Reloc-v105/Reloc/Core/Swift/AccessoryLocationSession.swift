import Foundation

public struct ProtocolEvent: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let name: String
    public let detail: String
    public let isError: Bool

    public init(timestamp: Date = Date(), name: String, detail: String, isError: Bool = false) {
        self.timestamp = timestamp
        self.name = name
        self.detail = detail
        self.isError = isError
    }
}

public struct SessionSnapshot: Equatable, Sendable {
    public var isRunning: Bool = false
    public var mode: SessionMode = .send
    public var linkReady: Bool = false
    public var identified: Bool = false
    public var authenticated: Bool = false
    public var activeSentences: [UInt16] = []
    public var packetsAcknowledged: Int = 0
    public var lastError: String? = nil

    public init() {}
}

public enum SessionMode: String, Sendable {
    case probe
    case send
}

public struct SessionConfiguration: Sendable {
    public var mode: SessionMode
    public var intervalSeconds: TimeInterval
    /// 0 means run continuously until stopped manually.
    public var durationSeconds: TimeInterval

    public init(
        mode: SessionMode = .send,
        intervalSeconds: TimeInterval = 1.0,
        durationSeconds: TimeInterval = 0
    ) {
        self.mode = mode
        self.intervalSeconds = max(1.0, intervalSeconds)
        self.durationSeconds = max(0, durationSeconds)
    }
}

/// Thread-safe holder for live target coordinates while a session is streaming.
public final class LiveLocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TargetLocation

    public init(_ initial: TargetLocation) {
        self.current = initial
    }

    public func get() -> TargetLocation {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func set(_ location: TargetLocation) {
        lock.lock()
        current = location
        lock.unlock()
    }
}

/// Runs iAP2 / MFi / NMEA through a software-only local accessory endpoint, hardened for
/// multi-hour continuous background operation (monotonic clocks, zero busy-wait polling,
/// background micro-jitter, and endless capped exponential backoff for transient disruptions).
public final class AccessoryLocationSession {
    public typealias EventCallback = @Sendable (ProtocolEvent) -> Void
    public typealias SnapshotCallback = @Sendable (SessionSnapshot) -> Void

    public let id: UUID
    private let queue = DispatchQueue(label: "com.reloc.session", qos: .userInitiated)
    private let stateLock = NSLock()
    private let sleepCondition = NSCondition()
    private var cancelled = false
    private var wakeReconnectRequested = false
    private var runGeneration: UInt64 = 0
    private var activeLink: IAP2Link?
    private var activeSocket: RLStreamSocket?
    private var activeVirtualTransport: RLVirtualAccessoryTransport?
    private var coreLocationConfirmed = false
    private var microJitterEnabled = false
    private var fastBurstUntil: TimeInterval = 0
    private var pendingKalmanReset = false
    private var burstMotionPacketsRemaining = 0
    private var pendingReconnectReason: String?
    private var fallbackRealLocation: TargetLocation?

    public let locationBox: LiveLocationBox
    private let trajectoryDriver: TrajectoryDriver?
    private let onEvent: EventCallback
    private let onSnapshot: SnapshotCallback
    private let onTrajectoryProgress: (@Sendable (TrajectoryProgress) -> Void)?
    private let onAuthenticated: (@Sendable () -> Void)?
    private let onLocationRequested: (@Sendable () -> Void)?
    private let onLocationStopped: (@Sendable () -> Void)?
    private let onSubscriptionRestarted: (@Sendable () -> Void)?
    private let onReconnecting: (@Sendable () -> Void)?

    public init(
        id: UUID = UUID(),
        initialLocation: TargetLocation,
        microJitterEnabled: Bool = false,
        trajectoryDriver: TrajectoryDriver? = nil,
        onEvent: @escaping EventCallback,
        onSnapshot: @escaping SnapshotCallback,
        onTrajectoryProgress: (@Sendable (TrajectoryProgress) -> Void)? = nil,
        onAuthenticated: (@Sendable () -> Void)? = nil,
        onLocationRequested: (@Sendable () -> Void)? = nil,
        onLocationStopped: (@Sendable () -> Void)? = nil,
        onSubscriptionRestarted: (@Sendable () -> Void)? = nil,
        onReconnecting: (@Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.locationBox = LiveLocationBox(initialLocation)
        self.microJitterEnabled = microJitterEnabled
        self.trajectoryDriver = trajectoryDriver
        self.onEvent = onEvent
        self.onSnapshot = onSnapshot
        self.onTrajectoryProgress = onTrajectoryProgress
        self.onAuthenticated = onAuthenticated
        self.onLocationRequested = onLocationRequested
        self.onLocationStopped = onLocationStopped
        self.onSubscriptionRestarted = onSubscriptionRestarted
        self.onReconnecting = onReconnecting
    }

    private static var monotonicNow: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Returns the live expected target coordinate (moving trajectory point when simulating a route,
    /// otherwise the static target coordinate) for accurate CoreLocation lock verification.
    public func currentComparisonLocation() -> TargetLocation {
        trajectoryDriver?.currentTargetLocation() ?? locationBox.get()
    }

    public func isTrajectoryWaitingForLock() -> Bool {
        trajectoryDriver?.isWaitingForLock() ?? false
    }

    /// Updates whether iOS CoreLocation has confirmed `isProducedByAccessory == true` for the target.
    public func markCoreLocationConfirmed(_ confirmed: Bool) {
        stateLock.lock()
        coreLocationConfirmed = confirmed
        let sock = activeSocket
        stateLock.unlock()
        if confirmed {
            if trajectoryDriver?.releaseStartLock() == true {
                emitEvent("trajectory_lock_released")
            }
            sock?.nudge()
        } else {
            if trajectoryDriver?.holdForRelock() == true {
                emitEvent("trajectory_held_for_relock")
            }
        }
    }

    public func setTrajectoryPaused(_ paused: Bool) {
        trajectoryDriver?.setPaused(paused)
        stateLock.lock()
        let sock = activeSocket
        stateLock.unlock()
        sock?.nudge()
    }

    public func setTrajectorySpeed(_ mps: Double) {
        trajectoryDriver?.setTargetSpeed(mps)
    }

    public func setTrajectoryPreset(_ preset: RouteTransportPreset) {
        trajectoryDriver?.setPreset(preset)
    }

    public func setTrajectoryLoopMode(_ mode: RouteLoopMode) {
        trajectoryDriver?.setLoopMode(mode)
    }

    public func setTrajectoryRealisticMotion(_ enabled: Bool) {
        trajectoryDriver?.setRealisticMotionEnabled(enabled)
    }

    /// Toggles stationary sub-meter GPS micro-jitter directly on the session thread (no main-thread timer).
    public func setMicroJitterEnabled(_ enabled: Bool) {
        stateLock.lock()
        microJitterEnabled = enabled
        let sock = activeSocket
        stateLock.unlock()
        sock?.nudge()
    }

    /// Stores the most recent known internal real location so stop-time accuracy degradation
    /// can gently hand control back to `locationd` indoors without user intervention.
    public func setFallbackRealLocation(_ location: TargetLocation?) {
        stateLock.lock()
        fallbackRealLocation = location
        stateLock.unlock()
    }

    /// Requests a temporary high-cadence NMEA acquisition burst (5 Hz)
    /// so `locationd` locks onto the external accessory GPS as rapidly as possible.
    public func triggerFastBurst(seconds: TimeInterval = 15.0) {
        stateLock.lock()
        fastBurstUntil = max(fastBurstUntil, Self.monotonicNow + seconds)
        let sock = activeSocket
        stateLock.unlock()
        sock?.nudge()
    }

    /// Wakes the streaming loop immediately on coordinate change, optionally emitting a brief
    /// void-fix pulse and micro-motion burst to reset `locationd`'s Kalman filter.
    public func notifyLocationUpdated(resetKalman: Bool = true, burstSeconds: TimeInterval = 10.0) {
        stateLock.lock()
        coreLocationConfirmed = false
        if resetKalman {
            pendingKalmanReset = true
            burstMotionPacketsRemaining = max(burstMotionPacketsRemaining, 2)
        }
        fastBurstUntil = max(fastBurstUntil, Self.monotonicNow + burstSeconds)
        let sock = activeSocket
        stateLock.unlock()
        sock?.nudge()
    }

    /// Requests a clean iAP2 link reset & immediate reconnect (e.g. if `0xFFFA` or lock stalls).
    public func requestLinkReconnect(reason: String) {
        stateLock.lock()
        pendingReconnectReason = reason
        let sock = activeSocket
        stateLock.unlock()
        sock?.nudge()
        wakeBackoffSleep()
    }

    /// Interrupts any exponential reconnect backoff immediately (e.g. when returning to foreground).
    public func wakeForImmediateReconnect() {
        wakeBackoffSleep()
    }

    private func wakeBackoffSleep() {
        sleepCondition.lock()
        wakeReconnectRequested = true
        sleepCondition.broadcast()
        sleepCondition.unlock()
    }

    private func consumeReconnectReason() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let reason = pendingReconnectReason
        pendingReconnectReason = nil
        return reason
    }

    private func isFastBurstActive(now: TimeInterval) -> Bool {
        stateLock.lock()
        let confirmed = coreLocationConfirmed
        let burstDeadline = fastBurstUntil
        stateLock.unlock()
        return !confirmed && now < burstDeadline
    }

    private func isConfirmedAndJitter() -> (confirmed: Bool, jitter: Bool) {
        stateLock.lock()
        let result = (coreLocationConfirmed, microJitterEnabled)
        stateLock.unlock()
        return result
    }

    /// Verifies a local virtual endpoint through a real iAP2 SYN exchange, without pairing.
    public static func verifyConnection() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let transport = try RLVirtualAccessoryTransport(eventHandler: nil)
                    defer { transport.close() }
                    let link = IAP2Link(socket: transport.socket)
                    try link.handshake()
                    link.sendReset()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Uses the same MFi / NMEA session and refresh workflow over a software-only endpoint.
    public func start(configuration: SessionConfiguration, mfiSigner: RLMFiSigner) {
        resetCancellation()
        queue.async { [weak self] in
            guard let self else { return }
            // Wall-clock deadline respects real elapsed time across device sleep / screen lock.
            let wallDeadline = configuration.durationSeconds > 0
                ? Date().addingTimeInterval(configuration.durationSeconds) : nil
            var finalSnapshot = SessionSnapshot()
            finalSnapshot.mode = configuration.mode
            finalSnapshot.isRunning = true
            self.onSnapshot(finalSnapshot)
            var shouldReconnect = true
            var consecutiveFailures = 0
            while shouldReconnect && !self.isCancelled() {
                if let wallDeadline, Date() >= wallDeadline { break }
                var reconnectDelay: TimeInterval = 0.5
                do {
                    let transport = try RLVirtualAccessoryTransport { [weak self] event, details in
                        self?.emitEvent(event, details: details)
                    }
                    self.stateLock.lock()
                    self.activeVirtualTransport = transport
                    let cancelled = self.cancelled
                    self.stateLock.unlock()
                    defer {
                        transport.close()
                        self.stateLock.lock()
                        self.activeVirtualTransport = nil
                        self.stateLock.unlock()
                    }
                    if cancelled { break }
                    let outcome = self.runOnSocket(
                        socket: transport.socket, configuration: configuration, mfiSigner: mfiSigner,
                        initialSnapshot: finalSnapshot, overallWallDeadline: wallDeadline, keepRunningOnExit: true
                    )
                    switch outcome {
                    case .completed(let count):
                        finalSnapshot.packetsAcknowledged = count
                        shouldReconnect = false
                    case .fatalError(let message):
                        finalSnapshot.lastError = message
                        shouldReconnect = false
                    case .reconnectRequested(let reason, let count):
                        finalSnapshot.packetsAcknowledged = count
                        consecutiveFailures = 0
                        reconnectDelay = 0.4
                        self.onReconnecting?()
                        self.emitEvent("virtual_accessory_reconnecting", details: ["reason": reason])
                    case .recoverableError(let message, let didSendPackets, let count):
                        finalSnapshot.packetsAcknowledged = count
                        if didSendPackets {
                            consecutiveFailures = 0
                            reconnectDelay = 0.5
                        } else {
                            consecutiveFailures += 1
                            reconnectDelay = min(30.0, 0.5 * pow(2.0, Double(min(consecutiveFailures - 1, 6))))
                        }
                        self.onReconnecting?()
                        self.emitEvent("virtual_accessory_reconnecting", details: [
                            "reason": message,
                            "backoff_s": reconnectDelay,
                        ])
                    }
                } catch {
                    let message = error.localizedDescription
                    let nsError = error as NSError
                    // Only stop permanently for incompatible framework/ABI errors (code == 2).
                    // Transient failures (e.g. accessoryd restart / screen-lock transition) keep retrying
                    // with capped exponential backoff so multi-hour sessions self-heal automatically.
                    let isPermanent = nsError.domain == "dev.reloc.virtual-accessory" && nsError.code == 2
                    consecutiveFailures += 1
                    self.emitEvent("virtual_accessory_error", details: [
                        "detail": message,
                        "attempt": consecutiveFailures,
                    ], isError: true)
                    if isPermanent {
                        finalSnapshot.lastError = message
                        shouldReconnect = false
                    } else {
                        finalSnapshot.lastError = message
                        self.onSnapshot(finalSnapshot)
                        self.onReconnecting?()
                        reconnectDelay = min(30.0, 0.5 * pow(2.0, Double(min(consecutiveFailures - 1, 6))))
                    }
                }
                if shouldReconnect {
                    self.sleepCancellable(reconnectDelay, wallDeadline: wallDeadline)
                }
            }
            finalSnapshot.isRunning = false
            self.onSnapshot(finalSnapshot)
        }
    }

    /// Starts directly over an already-connected socket (used for loopback unit testing).
    public func start(
        socket: RLStreamSocket,
        configuration: SessionConfiguration,
        mfiSigner: RLMFiSigner,
        completion: (() -> Void)? = nil
    ) {
        resetCancellation()
        queue.async { [weak self] in
            defer { completion?() }
            _ = self?.runOnSocket(
                socket: socket,
                configuration: configuration,
                mfiSigner: mfiSigner,
                initialSnapshot: SessionSnapshot()
            )
        }
    }

    public func stop() {
        stateLock.lock()
        cancelled = true
        let stopGeneration = runGeneration
        let hasActiveLink = (activeLink != nil)
        let sock = activeSocket
        stateLock.unlock()

        wakeBackoffSleep()
        sock?.nudge()

        if !hasActiveLink {
            forceCloseActiveTransports()
            return
        }

        // Give `runOnSocket` up to 0.9s to flush degraded/void NMEA and an iAP2 RST control packet
        // so iOS immediately detaches the external GPS accessory, then force-close as a failsafe.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let sameRunAndCancelled = (self.runGeneration == stopGeneration && self.cancelled)
            self.stateLock.unlock()
            if sameRunAndCancelled {
                self.forceCloseActiveTransports()
            }
        }
    }

    private func forceCloseActiveTransports() {
        stateLock.lock()
        let link = activeLink
        let virtualTransport = activeVirtualTransport
        stateLock.unlock()

        link?.close()
        virtualTransport?.close()
    }

    private func resetCancellation() {
        stateLock.lock()
        cancelled = false
        pendingKalmanReset = false
        burstMotionPacketsRemaining = 0
        pendingReconnectReason = nil
        runGeneration &+= 1
        stateLock.unlock()

        sleepCondition.lock()
        wakeReconnectRequested = false
        sleepCondition.unlock()
    }

    private func isCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func emitEvent(_ name: String, details: [String: Any] = [:], isError: Bool = false) {
        var payload = details
        payload["event"] = name
        let detailText: String
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: jsonData, encoding: .utf8) {
            detailText = str
        } else {
            detailText = "{\"event\":\"\(name)\"}"
        }
        onEvent(ProtocolEvent(name: name, detail: detailText, isError: isError))
    }

    private enum SocketRunOutcome {
        case completed(packetCount: Int)
        case reconnectRequested(String, packetCount: Int)
        case recoverableError(String, didSendPackets: Bool, packetCount: Int)
        case fatalError(String)
    }

    /// Zero-CPU-wakeup condition wait for reconnect backoff; wakes immediately on cancel or resume.
    private func sleepCancellable(_ seconds: TimeInterval, wallDeadline: Date?) {
        let nowDate = Date()
        var targetDate = nowDate.addingTimeInterval(max(0.01, seconds))
        if let wallDeadline, wallDeadline < targetDate {
            targetDate = wallDeadline
        }
        sleepCondition.lock()
        defer { sleepCondition.unlock() }
        wakeReconnectRequested = false
        while !isCancelled() && !wakeReconnectRequested {
            if Date() >= targetDate { break }
            _ = sleepCondition.wait(until: targetDate)
        }
        wakeReconnectRequested = false
    }

    private func runOnSocket(
        socket: RLStreamSocket,
        configuration: SessionConfiguration,
        mfiSigner: RLMFiSigner,
        initialSnapshot: SessionSnapshot,
        overallWallDeadline: Date? = nil,
        keepRunningOnExit: Bool = false
    ) -> SocketRunOutcome {
        var snapshot = initialSnapshot
        snapshot.isRunning = true
        snapshot.mode = configuration.mode
        let initialPacketCount = snapshot.packetsAcknowledged
        onSnapshot(snapshot)

        let link = IAP2Link(
            socket: socket,
            shouldCancel: { [weak self] in self?.isCancelled() ?? true }
        ) { [weak self] event, details in
            self?.emitEvent(event, details: details)
        }

        stateLock.lock()
        activeLink = link
        activeSocket = socket
        pendingKalmanReset = false
        burstMotionPacketsRemaining = 0
        stateLock.unlock()

        defer {
            link.close()
            stateLock.lock()
            activeLink = nil
            activeSocket = nil
            stateLock.unlock()
        }

        do {
            try link.handshake()
            snapshot.linkReady = true
            onSnapshot(snapshot)

            let startMonotonic = Self.monotonicNow
            let authDeadline = startMonotonic + 12.0
            let wallDeadline: Date? = overallWallDeadline ?? (
                configuration.durationSeconds > 0
                    ? Date().addingTimeInterval(configuration.durationSeconds)
                    : nil
            )

            var activeSentences = Set<UInt16>()
            var lastSent: [UInt16: TimeInterval] = [:]
            var minIntervals: [UInt16: TimeInterval] = [:]
            var sawLocationStopped = false

            while !isCancelled() {
                if let reconnectReason = consumeReconnectReason() {
                    if snapshot.authenticated {
                        if !activeSentences.isEmpty {
                            let voidMap = NMEAGenerator.voidLocationSentences()
                            let voidOutgoing = activeSentences.sorted().compactMap { voidMap[$0] }
                            if !voidOutgoing.isEmpty, let voidMsg = try? NMEAGenerator.locationMessage(sentences: voidOutgoing) {
                                link.sendBestEffort(voidMsg, timeout: 0.2)
                            }
                        }
                        link.sendReset()
                        emitEvent("iap2_link_reset_sent", details: ["reason": reconnectReason])
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    return .reconnectRequested(reconnectReason, packetCount: snapshot.packetsAcknowledged)
                }

                let now = Self.monotonicNow
                if let wallDeadline, Date() >= wallDeadline {
                    break
                }
                if !snapshot.authenticated && now >= authDeadline {
                    throw IAP2LinkError.timeout("Accessory identification/authentication timed out")
                }

                // Event-driven poll slice: sleep cleanly until the next NMEA frame is actually due.
                // Incoming iAP2 frames, coordinate updates, reconnect requests, and stop() all wake
                // `poll()` in < 1 ms via the socket or wake pipe.
                var pollSlice: TimeInterval
                if !snapshot.authenticated {
                    pollSlice = min(0.5, max(0.01, authDeadline - now))
                } else if configuration.mode == .send,
                          snapshot.identified,
                          !activeSentences.isEmpty {
                    let burstActive = isFastBurstActive(now: now)
                    stateLock.lock()
                    let hasKalmanReset = pendingKalmanReset
                    stateLock.unlock()
                    if hasKalmanReset {
                        pollSlice = 0.01
                    } else {
                        let effectiveInterval = trajectoryDriver != nil
                            ? min(configuration.intervalSeconds, 1.0)
                            : configuration.intervalSeconds
                        let nextDue = activeSentences.map { id -> TimeInterval in
                            let last = lastSent[id] ?? -.infinity
                            let minReq = minIntervals[id] ?? 0.25
                            let required = burstActive ? max(0.25, minReq) : max(effectiveInterval, minReq)
                            return last.isFinite ? (last + required) : now
                        }.min() ?? (now + 1.0)
                        pollSlice = min(2.0, max(0.01, nextDue - now))
                    }
                } else {
                    pollSlice = 1.0
                }
                if let wallDeadline {
                    let wallRemaining = wallDeadline.timeIntervalSinceNow
                    pollSlice = min(pollSlice, max(0.01, wallRemaining))
                }

                if let message = try link.receive(timeout: pollSlice) {
                    let fields = try RLIAP2Parameter.parseParameters(from: message.body)
                    emitEvent("message", details: [
                        "identifier": String(format: "0x%04x", message.identifier),
                        "parameters": fields.map { ["id": Int($0.identifier), "bytes": $0.data.count] },
                    ])

                    switch message.identifier {
                    case 0x1D00: // StartIdentification
                        let idMsg = try NMEAGenerator.identificationMessage()
                        try link.send(idMsg)

                    case 0x1D02: // IdentificationAccepted
                        snapshot.identified = true
                        onSnapshot(snapshot)
                        emitEvent("identification_accepted")

                    case 0x1D03: // IdentificationRejected
                        let rejectedIds = fields.map { Int($0.identifier) }
                        throw IAP2LinkError.protocolError("Identification rejected: \(rejectedIds)")

                    case 0xAA00: // RequestAuthenticationCertificate
                        let certBody = RLIAP2Parameter.encode(0, data: mfiSigner.certificateContainerData)
                        try link.send(RLIAP2Message(identifier: 0xAA01, body: certBody))

                    case 0xAA02: // RequestAuthenticationChallengeResponse
                        let challenges = fields.filter { $0.identifier == 0 }.map(\.data)
                        guard challenges.count == 1 else {
                            throw IAP2LinkError.protocolError("Invalid authentication challenge parameters")
                        }
                        let signature = try mfiSigner.signChallenge(challenges[0])
                        let sigBody = RLIAP2Parameter.encode(0, data: signature)
                        try link.send(RLIAP2Message(identifier: 0xAA03, body: sigBody))

                    case 0xAA05: // AuthenticationSucceeded
                        snapshot.authenticated = true
                        snapshot.lastError = nil
                        onSnapshot(snapshot)
                        emitEvent("authentication_succeeded")
                        onAuthenticated?()

                    case 0xAA04: // AuthenticationFailed
                        throw IAP2LinkError.protocolError("Accessory authentication failed (0xAA04)")

                    case 0xFFFA: // StartLocationInformation
                        activeSentences = Set(
                            fields
                                .filter { ($0.identifier == 1 || $0.identifier == 2) && $0.data.isEmpty }
                                .map(\.identifier)
                        )
                        minIntervals.removeAll()
                        var minIntervalsMsLog: [String: Int] = [:]
                        for field in fields where (field.identifier == 0x8001 || field.identifier == 0x8002) && field.data.count == 4 {
                            let ms = field.data.withUnsafeBytes { ptr -> UInt32 in
                                let raw = ptr.load(as: UInt32.self)
                                return UInt32(bigEndian: raw)
                            }
                            let sid = field.identifier - 0x8000
                            minIntervals[sid] = max(0.2, Double(ms) / 1000.0)
                            minIntervalsMsLog["\(sid)"] = Int(ms)
                        }
                        lastSent.removeAll()
                        stateLock.lock()
                        pendingKalmanReset = false
                        burstMotionPacketsRemaining = 0
                        stateLock.unlock()
                        triggerFastBurst(seconds: 15.0)
                        snapshot.activeSentences = activeSentences.sorted()
                        onSnapshot(snapshot)
                        emitEvent("location_requested", details: [
                            "sentences": snapshot.activeSentences.map(Int.init),
                            "min_intervals_ms": minIntervalsMsLog,
                        ])
                        onLocationRequested?()
                        if sawLocationStopped {
                            sawLocationStopped = false
                            onSubscriptionRestarted?()
                        }

                    case 0xFFFC: // StopLocationInformation
                        sawLocationStopped = true
                        activeSentences.removeAll()
                        snapshot.activeSentences = []
                        onSnapshot(snapshot)
                        emitEvent("location_stopped")
                        onLocationStopped?()

                    default:
                        break
                    }
                }

                if configuration.mode == .send,
                   snapshot.identified,
                   snapshot.authenticated,
                   !activeSentences.isEmpty,
                   !isCancelled() {
                    stateLock.lock()
                    let shouldResetKalman = pendingKalmanReset
                    pendingKalmanReset = false
                    stateLock.unlock()

                    if shouldResetKalman {
                        lastSent.removeAll()
                        let voidMap = NMEAGenerator.voidLocationSentences()
                        let voidOutgoing = activeSentences.sorted().compactMap { voidMap[$0] }
                        if !voidOutgoing.isEmpty, let voidMsg = try? NMEAGenerator.locationMessage(sentences: voidOutgoing) {
                            link.sendBestEffort(voidMsg, timeout: 0.2)
                            emitEvent("kalman_reset_void_sent")
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                    }

                    let tickNow = Self.monotonicNow
                    let burstActive = isFastBurstActive(now: tickNow)
                    let effectiveInterval = trajectoryDriver != nil
                        ? min(configuration.intervalSeconds, 1.0)
                        : configuration.intervalSeconds
                    let due = activeSentences.sorted().filter { id in
                        let last = lastSent[id] ?? -.infinity
                        let minReq = minIntervals[id] ?? 0.25
                        let required = burstActive ? max(0.25, minReq) : max(effectiveInterval, minReq)
                        return tickNow - last >= required
                    }
                    if !due.isEmpty {
                        let (confirmed, jitter) = isConfirmedAndJitter()
                        var target: TargetLocation
                        if let driver = trajectoryDriver {
                            let step = driver.advance(toMonotonicTime: tickNow, stationaryJitter: jitter)
                            target = step.location
                            locationBox.set(target)
                            if step.didTeleportLap {
                                let voidMap = NMEAGenerator.voidLocationSentences()
                                let voidOutgoing = activeSentences.sorted().compactMap { voidMap[$0] }
                                if !voidOutgoing.isEmpty, let voidMsg = try? NMEAGenerator.locationMessage(sentences: voidOutgoing) {
                                    link.sendBestEffort(voidMsg, timeout: 0.2)
                                    Thread.sleep(forTimeInterval: 0.04)
                                }
                            }
                            onTrajectoryProgress?(step.progress)
                        } else {
                            target = locationBox.get()
                            if jitter {
                                target = CoordinateTransform.applyMicroJitter(to: target)
                            }
                        }

                        stateLock.lock()
                        if burstMotionPacketsRemaining > 0 {
                            burstMotionPacketsRemaining -= 1
                            if target.speedKnots == 0 {
                                target.speedKnots = 0.4
                            }
                        }
                        stateLock.unlock()

                        let sentenceMap = try NMEAGenerator.locationSentences(for: target, hdop: 0.5, fixQuality: 2)
                        let outgoing = due.compactMap { sentenceMap[$0] }
                        let locMsg = try NMEAGenerator.locationMessage(sentences: outgoing)
                        try link.send(locMsg)

                        for id in due {
                            lastSent[id] = tickNow
                        }
                        let hadError = snapshot.lastError != nil
                        snapshot.packetsAcknowledged += 1
                        snapshot.lastError = nil

                        // During acquisition (unconfirmed), push every ACK to update the live status pill.
                        // Once confirmed in steady state, throttle pure counter updates to reduce main-thread wakeups.
                        if !confirmed || hadError || snapshot.packetsAcknowledged == 1 || snapshot.packetsAcknowledged % 15 == 0 {
                            onSnapshot(snapshot)
                        }

                        if snapshot.packetsAcknowledged == 1
                            || snapshot.packetsAcknowledged == 10
                            || snapshot.packetsAcknowledged % 60 == 0 {
                            emitEvent("location_link_acknowledged", details: [
                                "count": snapshot.packetsAcknowledged,
                                "lat": String(format: "%.6f", target.latitude),
                                "lon": String(format: "%.6f", target.longitude),
                                "alt": String(format: "%.1f", target.altitude),
                            ])
                        }
                    }
                }
            }

            if isCancelled() && snapshot.authenticated {
                // Step 1: Degrade cached accessory accuracy (HDOP 35.0) toward fallback real coordinate
                // so indoor Wi-Fi/Cell positioning immediately outranks the accessory cache.
                if !activeSentences.isEmpty {
                    stateLock.lock()
                    let degradeLoc = fallbackRealLocation ?? locationBox.get()
                    stateLock.unlock()
                    if let degradedMap = try? NMEAGenerator.locationSentences(for: degradeLoc, hdop: 35.0, fixQuality: 1) {
                        let degradedOutgoing = activeSentences.sorted().compactMap { degradedMap[$0] }
                        if !degradedOutgoing.isEmpty,
                           let degradedMsg = try? NMEAGenerator.locationMessage(sentences: degradedOutgoing) {
                            link.sendBestEffort(degradedMsg, timeout: 0.2)
                            Thread.sleep(forTimeInterval: 0.04)
                        }
                    }

                    // Step 2: Emit invalid/void NMEA fix (GGA quality=0 / RMC status=V).
                    let voidMap = NMEAGenerator.voidLocationSentences()
                    let voidOutgoing = activeSentences.sorted().compactMap { voidMap[$0] }
                    if !voidOutgoing.isEmpty, let voidMsg = try? NMEAGenerator.locationMessage(sentences: voidOutgoing) {
                        link.sendBestEffort(voidMsg, timeout: 0.2)
                        emitEvent("location_void_sent", details: ["sentences": activeSentences.sorted().map(Int.init)])
                        Thread.sleep(forTimeInterval: 0.04)
                    }
                }
                // Step 3: Send iAP2 RST control packet so iOS detaches the accessory immediately.
                link.sendReset()
                emitEvent("iap2_link_reset_sent")
                Thread.sleep(forTimeInterval: 0.04)
            }

            emitEvent("finished", details: [
                "identified": snapshot.identified,
                "authenticated": snapshot.authenticated,
                "location_packets_acknowledged": snapshot.packetsAcknowledged,
            ])
            if !keepRunningOnExit {
                snapshot.isRunning = false
                onSnapshot(snapshot)
            }
            return .completed(packetCount: snapshot.packetsAcknowledged)
        } catch {
            if isCancelled() {
                emitEvent("stopped", details: ["reason": "user_cancelled"])
                if !keepRunningOnExit {
                    snapshot.isRunning = false
                    onSnapshot(snapshot)
                }
                return .completed(packetCount: snapshot.packetsAcknowledged)
            }
            let message = error.localizedDescription
            let isFatal = message.contains("0xAA04") || message.contains("Identification rejected")
            if isFatal || !keepRunningOnExit {
                snapshot.lastError = message
                emitEvent("error", details: ["detail": message], isError: true)
                snapshot.isRunning = false
                onSnapshot(snapshot)
                return isFatal ? .fatalError(message) : .recoverableError(
                    message,
                    didSendPackets: snapshot.packetsAcknowledged > initialPacketCount,
                    packetCount: snapshot.packetsAcknowledged
                )
            }
            return .recoverableError(
                message,
                didSendPackets: snapshot.packetsAcknowledged > initialPacketCount,
                packetCount: snapshot.packetsAcknowledged
            )
        }
    }
}

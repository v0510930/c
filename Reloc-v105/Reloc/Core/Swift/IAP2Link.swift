import Foundation

public enum IAP2LinkError: LocalizedError {
    case timeout(String)
    case protocolError(String)
    case linkReset

    public var errorDescription: String? {
        switch self {
        case .timeout(let msg): return msg
        case .protocolError(let msg): return msg
        case .linkReset: return "Peer reset the iAP2 link (RST)"
        }
    }
}

/// Stop-and-wait iAP2 link implementation over RLStreamSocket (faithful port of link.py).
public final class IAP2Link {
    private let socket: RLStreamSocket
    private let emit: (String, [String: Any]) -> Void
    private let shouldCancel: () -> Bool

    private var sequence: UInt8
    private var peerSequence: UInt8 = 0
    private let controlSession: UInt8 = 1
    private var maximumPacket: Int = 4096
    private var retransmitSeconds: TimeInterval = 2.0

    private var messageQueue: [RLIAP2Message] = []
    private let assembler = RLIAP2MessageBuffer()
    private var pendingHeader: Data?

    public init(
        socket: RLStreamSocket,
        shouldCancel: @escaping () -> Bool = { false },
        emit: @escaping (String, [String: Any]) -> Void = { _, _ in }
    ) {
        self.socket = socket
        self.shouldCancel = shouldCancel
        self.emit = emit
        self.sequence = UInt8.random(in: 0...255)
    }

    public func close() {
        socket.close()
    }

    /// Sends an iAP2 Link Reset (`RST`) control packet so the local CoreAccessories endpoint
    /// detaches the external GPS accessory immediately instead of waiting for TCP keepalive timeout.
    public func sendReset() {
        let rst = RLIAP2Packet(
            flags: RLIAP2LinkFlags.RST.rawValue,
            sequence: sequence,
            acknowledgement: peerSequence,
            session: 0,
            payload: nil
        )
        try? socket.write(rst.encode(), timeout: 0.35)
    }

    private static var monotonicNow: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func readPacket(timeout: TimeInterval) throws -> RLIAP2Packet? {
        let deadline = Self.monotonicNow + max(timeout, 0.001)

        if pendingHeader == nil {
            var timedOut: ObjCBool = false
            do {
                let header = try socket.readExactLength(9, timeout: timeout, timedOut: &timedOut)
                pendingHeader = header
            } catch {
                if timedOut.boolValue {
                    return nil
                }
                throw error
            }
        }

        guard let header = pendingHeader else { return nil }
        var totalSize: UInt16 = 0
        var headerErr: NSError?
        totalSize = RLIAP2Packet.validateHeaderData(header, error: &headerErr)
        if totalSize == 0 {
            pendingHeader = nil
            throw headerErr ?? IAP2LinkError.protocolError("Malformed iAP2 header")
        }

        if totalSize == 9 {
            pendingHeader = nil
            return try RLIAP2Packet.decode(from: header)
        }

        let remaining = max(deadline - Self.monotonicNow, 0.001)
        var timedOut: ObjCBool = false
        let rest: Data
        do {
            rest = try socket.readExactLength(UInt(totalSize - 9), timeout: remaining, timedOut: &timedOut)
        } catch {
            if timedOut.boolValue {
                // Keep pendingHeader intact so partial packet is preserved across timeouts!
                return nil
            }
            pendingHeader = nil
            throw error
        }

        pendingHeader = nil
        var full = Data(capacity: Int(totalSize))
        full.append(header)
        full.append(rest)
        return try RLIAP2Packet.decode(from: full)
    }

    private func writePacket(_ packet: RLIAP2Packet, timeout: TimeInterval? = nil) throws {
        let encoded = packet.encode()
        guard encoded.count >= 9 else {
            throw IAP2LinkError.protocolError("iAP2 packet exceeds maximum frame length")
        }
        try socket.write(encoded, timeout: timeout ?? max(retransmitSeconds, 2.0))
    }

    public func handshake() throws {
        // SYN link-parameter block: version=1, window=1, maxLen=4096, retry=2000ms, cumAck=22ms, maxRetrans=5, maxCumAck=1
        // + session triplet (id=1, type=0 Control, version=2)
        var offer = Data()
        offer.append(1) // version
        offer.append(1) // max outstanding packets
        offer.append(contentsOf: [0x10, 0x00]) // 4096 big-endian
        offer.append(contentsOf: [0x07, 0xD0]) // 2000 ms
        offer.append(contentsOf: [0x00, 0x16]) // 22 ms
        offer.append(5) // max retransmissions
        offer.append(1) // max cumulative acks
        offer.append(contentsOf: [1, 0, 2]) // control session (1, 0, 2)

        let syn = RLIAP2Packet(
            flags: RLIAP2LinkFlags.SYN.rawValue,
            sequence: sequence,
            acknowledgement: 0,
            session: 0,
            payload: offer
        )

        let synAckMask = RLIAP2LinkFlags.SYN.rawValue | RLIAP2LinkFlags.ACK.rawValue

        for _ in 0..<3 {
            if shouldCancel() {
                throw IAP2LinkError.timeout("iAP2 handshake cancelled")
            }
            try writePacket(syn)
            let attemptDeadline = Self.monotonicNow + 2.0
            var response: RLIAP2Packet?
            while !shouldCancel() {
                let remaining = attemptDeadline - Self.monotonicNow
                if remaining <= 0 { break }
                guard let candidate = try readPacket(timeout: remaining) else {
                    if Self.monotonicNow >= attemptDeadline { break }
                    continue
                }
                if (candidate.flags & RLIAP2LinkFlags.RST.rawValue) != 0 {
                    throw IAP2LinkError.linkReset
                }
                if (candidate.flags & synAckMask) == synAckMask {
                    response = candidate
                    break
                }
            }
            guard let response else {
                continue
            }
            let payload = response.payload
            if response.acknowledgement != sequence || payload.count < 13 {
                throw IAP2LinkError.protocolError("Invalid handshake acknowledgement or parameters")
            }

            let version = payload[0]
            let window = payload[1]
            let maxSize = Int(UInt16(payload[2]) << 8 | UInt16(payload[3]))
            let retryMs = Int(UInt16(payload[4]) << 8 | UInt16(payload[5]))
            let sessions = payload.subdata(in: 10..<payload.count)

            if version != 1 || window < 1 || maxSize < 10 || sessions.count % 3 != 0 {
                throw IAP2LinkError.protocolError("Unsupported peer iAP2 link parameters")
            }

            var hasControlSession = false
            for idx in stride(from: 0, to: sessions.count, by: 3) {
                if sessions[idx] == 1 && sessions[idx + 1] == 0 && sessions[idx + 2] == 2 {
                    hasControlSession = true
                    break
                }
            }
            if !hasControlSession {
                throw IAP2LinkError.protocolError("Peer did not accept control session (1, 0, 2)")
            }

            maximumPacket = min(maxSize, 4096)
            retransmitSeconds = max(Double(retryMs) / 1000.0, 0.1)
            peerSequence = response.sequence
            try acknowledge()
            emit("link_ready", [
                "control_session": Int(controlSession),
                "max_packet": maximumPacket,
                "retransmit_ms": retryMs,
            ])
            return
        }

        throw IAP2LinkError.timeout("No iAP2 SYN acknowledgement from device")
    }

    public func acknowledge() throws {
        let ack = RLIAP2Packet(
            flags: RLIAP2LinkFlags.ACK.rawValue,
            sequence: sequence,
            acknowledgement: peerSequence,
            session: 0,
            payload: nil
        )
        try writePacket(ack)
    }

    public func accept(_ packet: RLIAP2Packet) throws {
        if (packet.flags & RLIAP2LinkFlags.RST.rawValue) != 0 {
            throw IAP2LinkError.linkReset
        }
        if (packet.flags & RLIAP2LinkFlags.SYN.rawValue) != 0 {
            if packet.sequence != peerSequence {
                throw IAP2LinkError.protocolError("Unexpected new SYN during established link")
            }
            try acknowledge()
            return
        }
        if !packet.payload.isEmpty && (packet.flags & RLIAP2LinkFlags.EAK.rawValue) == 0 {
            let expectedNext = peerSequence &+ 1
            if packet.sequence == expectedNext {
                peerSequence = packet.sequence
                if packet.session != controlSession {
                    throw IAP2LinkError.protocolError("Data received on unnegotiated session \(packet.session)")
                }
                let assembled = try assembler.feed(packet.payload)
                messageQueue.append(contentsOf: assembled)
            }
            // Acknowledge last contiguous sequence; duplicate/out-of-order packets are suppressed.
            try acknowledge()
        }
    }

    public func send(_ message: RLIAP2Message) throws {
        let raw = message.encode()
        guard raw.count >= 6 else {
            throw IAP2LinkError.protocolError("iAP2 message exceeds maximum length")
        }
        let chunkLimit = max(1, maximumPacket - 10)

        var offset = 0
        while offset < raw.count {
            let end = min(offset + chunkLimit, raw.count)
            let chunk = raw.subdata(in: offset..<end)
            offset = end

            sequence = sequence &+ 1
            var acknowledged = false

            for attempt in 1...6 {
                if shouldCancel() {
                    throw IAP2LinkError.timeout("iAP2 send cancelled")
                }
                let pkt = RLIAP2Packet(
                    flags: RLIAP2LinkFlags.ACK.rawValue,
                    sequence: sequence,
                    acknowledgement: peerSequence,
                    session: controlSession,
                    payload: chunk
                )
                try writePacket(pkt)

                let deadline = Self.monotonicNow + retransmitSeconds
                while !shouldCancel() {
                    let remaining = deadline - Self.monotonicNow
                    if remaining <= 0 { break }
                    guard let incoming = try readPacket(timeout: remaining) else {
                        // A non-cancellation socket.nudge() (e.g. live coordinate update) can wake
                        // readPacket early; keep waiting for the peer ACK until the true deadline.
                        if Self.monotonicNow >= deadline || shouldCancel() {
                            break
                        }
                        continue
                    }
                    try accept(incoming)
                    if (incoming.flags & RLIAP2LinkFlags.ACK.rawValue) != 0 &&
                        incoming.acknowledgement == sequence {
                        acknowledged = true
                        break
                    }
                }
                if acknowledged { break }
                if shouldCancel() {
                    throw IAP2LinkError.timeout("iAP2 send cancelled")
                }
                emit("retransmit", ["attempt": attempt])
            }

            if !acknowledged {
                throw IAP2LinkError.timeout("Peer did not acknowledge iAP2 data packet")
            }
        }
    }

    /// Sends a short control/location message once with a bounded wait so teardown/reset flushes never stall.
    public func sendBestEffort(_ message: RLIAP2Message, timeout: TimeInterval = 0.25) {
        let raw = message.encode()
        guard raw.count >= 6 else { return }
        let chunkLimit = max(1, maximumPacket - 10)
        var offset = 0
        while offset < raw.count {
            let end = min(offset + chunkLimit, raw.count)
            let chunk = raw.subdata(in: offset..<end)
            offset = end

            sequence = sequence &+ 1
            let pkt = RLIAP2Packet(
                flags: RLIAP2LinkFlags.ACK.rawValue,
                sequence: sequence,
                acknowledgement: peerSequence,
                session: controlSession,
                payload: chunk
            )
            do {
                try writePacket(pkt, timeout: timeout)
                let deadline = Self.monotonicNow + min(0.2, timeout)
                while true {
                    let remaining = deadline - Self.monotonicNow
                    if remaining <= 0 { break }
                    guard let incoming = try readPacket(timeout: remaining) else { break }
                    try accept(incoming)
                    if (incoming.flags & RLIAP2LinkFlags.ACK.rawValue) != 0 &&
                        incoming.acknowledgement == sequence {
                        break
                    }
                }
            } catch {
                return
            }
        }
    }

    public func receive(timeout: TimeInterval) throws -> RLIAP2Message? {
        let deadline = Self.monotonicNow + timeout
        while messageQueue.isEmpty {
            let remaining = deadline - Self.monotonicNow
            if remaining <= 0 {
                return nil
            }
            guard let packet = try readPacket(timeout: remaining) else {
                return nil
            }
            try accept(packet)
        }
        return messageQueue.removeFirst()
    }
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CrateEngine
import Foundation

/// Receives complete FIDO HID reports away from crate's guest CPU threads.
///
/// A backend can forward the reports to a physical security key or implement
/// an authenticator whose private keys remain in the Secure Enclave. It sends
/// each response report back with `send(_:in:)`. Delegate callbacks are on the
/// main actor; console bytes are copied before crate's callback returns.
@MainActor
protocol CredentialConsoleBridgeDelegate: AnyObject {
    func credentialConsoleBridge(_ bridge: CredentialConsoleBridge,
                                 received report: CredentialConsoleBridge.Report,
                                 in session: CredentialConsoleBridge.Session)
    func credentialConsoleBridge(_ bridge: CredentialConsoleBridge,
                                 invalidated session: CredentialConsoleBridge.Session,
                                 because reason: CredentialConsoleBridge.InvalidationReason)
}

extension CredentialConsoleBridgeDelegate {
    func credentialConsoleBridge(_: CredentialConsoleBridge,
                                 invalidated _: CredentialConsoleBridge.Session,
                                 because _: CredentialConsoleBridge.InvalidationReason) {}
}

/// A CFD1-framed FIDO report transport over a dedicated virtio console.
///
/// Virtio consoles are arbitrary byte streams. CFD1 supplies versioned frame
/// boundaries, CRC-based resynchronization, per-direction sequences and a
/// fresh guest nonce handshake. This bridge deliberately knows nothing about
/// CTAP, credentials, passwords or biometric policy.
final class CredentialConsoleBridge: @unchecked Sendable {
    typealias ConsoleWriter = (OpaquePointer, UInt32, UnsafePointer<UInt8>?, Int) -> Int

    struct Report: Equatable, Sendable {
        static let byteCount = 64
        let bytes: [UInt8]

        init?(_ bytes: [UInt8]) {
            guard bytes.count == Self.byteCount else { return nil }
            self.bytes = bytes
        }

        fileprivate init(unchecked bytes: [UInt8]) {
            self.bytes = bytes
        }
    }

    /// Opaque binding for either a machine lifecycle or one accepted HELLO.
    /// Backends only receive handshake bindings; MachineRunner keeps the
    /// lifecycle binding returned by `reset()`.
    struct Session: Hashable, Sendable {
        fileprivate let generation: UInt64
    }

    enum SendResult: Equatable, Sendable {
        case accepted
        case staleSession
        case notAttached
        /// Nothing was dropped into a live stream: the session was invalidated.
        case queueFull
    }

    enum InvalidationReason: Sendable {
        case reset
        case detached
        case inboundOverflow
        case outboundOverflow
        case invalidConsole
        case protocolViolation
    }

    private enum Wire {
        static let magic: [UInt8] = [0x43, 0x46, 0x44, 0x31] // CFD1
        static let version: UInt8 = 1
        static let headerSize = 16
        static let maximumPayload = 64
        static let maximumFrameSize = headerSize + maximumPayload
        static let parserCapacity = 4096
        static let nonceSize = 16

        static let hello: UInt8 = 0x01
        static let helloAck: UInt8 = 0x02
        static let guestReport: UInt8 = 0x10
        static let hostReport: UInt8 = 0x11
    }

    /// A maximum-size CTAP HID message needs 129 reports; leave bounded room
    /// for another in-flight channel and keepalive/cancel traffic as well.
    private static let maximumQueuedReports = 256
    private static let maximumQueuedWireBytes = maximumQueuedReports * Wire.maximumFrameSize

    private let lock = NSLock()
    private let consoleWriter: ConsoleWriter
    /// Does framing and crate writes without keeping a guest CPU thread busy.
    private let transportQueue = DispatchQueue(label: "com.amendez.crate.credential-console",
                                               qos: .userInitiated)

    private var nextGeneration: UInt64 = 0
    /// Exists from MachineRunner.reset through detach, including before HELLO.
    private var lifecycleSession: Session?
    /// Replaced by every valid HELLO, even one repeating the same nonce.
    private var backendSession: Session?
    private var consoleIndex: UInt32?
    private var machine: OpaquePointer?

    private var expectedGuestSequence: UInt32?
    private var nextHostSequence: UInt32 = 0
    private var parserBytes: [UInt8] = []

    /// Copied in crate's output callback, then consumed on `transportQueue`.
    private var inboundChunks: [(Session, [UInt8])] = []
    private var inboundChunkBytes = 0
    private var inboundDrainScheduled = false
    private var inboundReports: [(Session, Report)] = []
    private var deliveryScheduled = false

    /// Complete CFD1 frames, possibly partly accepted by crate.
    private var outboundStream: [UInt8] = []
    private var outboundOffset = 0
    private var waitingForInputReady = false
    private var writeScheduled = false

    @MainActor weak var delegate: CredentialConsoleBridgeDelegate?

    init(consoleWriter: @escaping ConsoleWriter = { machine, console, bytes, length in
        crate_console_write(machine, console, bytes, length)
    }) {
        self.consoleWriter = consoleWriter
    }

    /// For `crate_config_add_console`; this bridge outlives every machine.
    var callbacks: crate_console_callbacks {
        crate_console_callbacks(
            size: MemoryLayout<crate_console_callbacks>.size,
            context: Unmanaged.passUnretained(self).toOpaque(),
            output: { context, console, bytes, length in
                guard let context, length == 0 || bytes != nil else { return }
                let bridge = Unmanaged<CredentialConsoleBridge>.fromOpaque(context).takeUnretainedValue()
                guard let bytes, length != 0 else { return }
                bridge.copyOutput(console: console,
                                  bytes: UnsafeBufferPointer(start: bytes, count: length))
            },
            input_ready: { context, console in
                guard let context else { return }
                Unmanaged<CredentialConsoleBridge>.fromOpaque(context).takeUnretainedValue()
                    .inputReady(console: console)
            })
    }

    /// Starts a clean machine transport before its console is configured.
    @discardableResult
    func reset() -> Session {
        let result = lock.withLock { () -> (Session, Session?) in
            let invalidated = invalidateLifecycleLocked()
            let fresh = makeSessionLocked()
            lifecycleSession = fresh
            return (fresh, invalidated)
        }
        if let invalidated = result.1 { notifyInvalidated(invalidated, because: .reset) }
        return result.0
    }

    /// Records the index crate actually assigned. Console numbers are counted
    /// over serial and virtio consoles together, so they must never be guessed.
    @discardableResult
    func configure(index: UInt32, in expected: Session) -> Bool {
        lock.withLock {
            guard lifecycleSession == expected, consoleIndex == nil, machine == nil else { return false }
            consoleIndex = index
            return true
        }
    }

    /// Makes framed responses writable immediately before the machine starts.
    @discardableResult
    func attach(machine: OpaquePointer, in expected: Session) -> Bool {
        lock.withLock {
            guard lifecycleSession == expected, consoleIndex != nil, self.machine == nil else { return false }
            self.machine = machine
            return true
        }
    }

    /// Stops all callbacks and writes for this exact machine. Late backend
    /// responses carry a HELLO binding and are therefore rejected.
    func detach(_ expected: Session) {
        let invalidated = lock.withLock { () -> Session? in
            guard lifecycleSession == expected else { return nil }
            return invalidateLifecycleLocked()
        }
        if let invalidated { notifyInvalidated(invalidated, because: .detached) }
    }

    /// Frames one authenticator-to-guest report. The queue is deliberately
    /// finite; overflow invalidates the stream instead of losing alignment.
    @discardableResult
    func send(_ report: Report, in expected: Session) -> SendResult {
        let result = lock.withLock { () -> (SendResult, Session?) in
            guard backendSession == expected else { return (.staleSession, nil) }
            guard lifecycleSession != nil, machine != nil, consoleIndex != nil else {
                return (.notAttached, nil)
            }
            guard let frame = Self.encodeFrame(type: Wire.hostReport,
                                               sequence: nextHostSequence,
                                               payload: report.bytes) else {
                return (.staleSession, invalidateLifecycleLocked())
            }
            let pending = outboundStream.count - outboundOffset
            guard pending <= Self.maximumQueuedWireBytes - frame.count else {
                return (.queueFull, invalidateLifecycleLocked())
            }
            nextHostSequence &+= 1
            outboundStream.append(contentsOf: frame)
            scheduleWriteLocked()
            return (.accepted, nil)
        }
        if let invalidated = result.1 { notifyInvalidated(invalidated, because: .outboundOverflow) }
        return result.0
    }

    // MARK: - crate callbacks

    /// Copies while crate's pointer is valid, then leaves framing and delegate
    /// work to queues crate does not run its vCPUs on.
    private func copyOutput(console: UInt32, bytes: UnsafeBufferPointer<UInt8>) {
        let expected = lock.withLock { () -> Session? in
            guard let lifecycleSession, machine != nil else { return nil }
            return consoleIndex == console ? lifecycleSession : nil
        }
        guard let expected else {
            invalidateForWrongConsoleIfNeeded(console)
            return
        }
        guard bytes.count <= Self.maximumQueuedWireBytes else {
            invalidateLifecycle(expected, because: .inboundOverflow)
            return
        }
        let copy = Array(bytes)
        let invalidated = lock.withLock { () -> Session? in
            guard lifecycleSession == expected, machine != nil, consoleIndex == console else { return nil }
            guard inboundChunkBytes <= Self.maximumQueuedWireBytes - copy.count else {
                return invalidateLifecycleLocked()
            }
            inboundChunks.append((expected, copy))
            inboundChunkBytes += copy.count
            scheduleInboundDrainLocked()
            return nil
        }
        if let invalidated { notifyInvalidated(invalidated, because: .inboundOverflow) }
    }

    private func inputReady(console: UInt32) {
        let invalidated = lock.withLock { () -> Session? in
            guard lifecycleSession != nil, machine != nil else { return nil }
            guard consoleIndex == console else { return invalidateLifecycleLocked() }
            waitingForInputReady = false
            scheduleWriteLocked()
            return nil
        }
        if let invalidated { notifyInvalidated(invalidated, because: .invalidConsole) }
    }

    private func invalidateForWrongConsoleIfNeeded(_ console: UInt32) {
        let invalidated = lock.withLock { () -> Session? in
            guard lifecycleSession != nil, machine != nil,
                  let consoleIndex, consoleIndex != console else { return nil }
            return invalidateLifecycleLocked()
        }
        if let invalidated { notifyInvalidated(invalidated, because: .invalidConsole) }
    }

    // MARK: - Guest to backend

    /// Under `lock`.
    private func scheduleInboundDrainLocked() {
        guard !inboundDrainScheduled else { return }
        inboundDrainScheduled = true
        transportQueue.async { [weak self] in self?.drainInbound() }
    }

    private func drainInbound() {
        while true {
            let chunk = lock.withLock { () -> (Session, [UInt8])? in
                guard !inboundChunks.isEmpty else {
                    inboundDrainScheduled = false
                    return nil
                }
                let chunk = inboundChunks.removeFirst()
                inboundChunkBytes -= chunk.1.count
                return chunk
            }
            guard let (expected, bytes) = chunk else { return }
            consume(bytes, in: expected)
        }
    }

    private func consume(_ bytes: [UInt8], in expected: Session) {
        var notifications: [(Session, InvalidationReason)] = []
        lock.withLock {
            guard lifecycleSession == expected, machine != nil else { return }
            var offset = 0
            while offset < bytes.count, lifecycleSession == expected {
                parseAvailableLocked(notifications: &notifications)
                guard lifecycleSession == expected else { break }
                if parserBytes.count == Wire.parserCapacity {
                    parserBytes.removeFirst()
                    continue
                }
                let take = min(bytes.count - offset, Wire.parserCapacity - parserBytes.count)
                parserBytes.append(contentsOf: bytes[offset..<(offset + take)])
                offset += take
            }
            if lifecycleSession == expected {
                parseAvailableLocked(notifications: &notifications)
            }
        }
        for (session, reason) in notifications {
            notifyInvalidated(session, because: reason)
        }
    }

    /// Parses every complete frame currently buffered. Invalid candidates move
    /// forward by one byte, preserving a possible `CFD1` prefix at the end.
    /// Under `lock`.
    private func parseAvailableLocked(notifications: inout [(Session, InvalidationReason)]) {
        while lifecycleSession != nil {
            guard let marker = magicOffset(in: parserBytes) else {
                let keep = magicPrefixAtEnd(parserBytes)
                if parserBytes.count > keep { parserBytes.removeFirst(parserBytes.count - keep) }
                return
            }
            if marker != 0 { parserBytes.removeFirst(marker) }
            guard parserBytes.count >= Wire.headerSize else { return }

            let version = parserBytes[4]
            let length = Int(Self.loadBE16(parserBytes, at: 6))
            guard version == Wire.version, length <= Wire.maximumPayload else {
                protocolViolationLocked(notifications: &notifications)
                parserBytes.removeFirst()
                continue
            }
            let total = Wire.headerSize + length
            guard parserBytes.count >= total else { return }
            let expectedCRC = Self.loadBE32(parserBytes, at: 12)
            guard Self.frameCRC(parserBytes, payloadLength: length) == expectedCRC else {
                protocolViolationLocked(notifications: &notifications)
                parserBytes.removeFirst()
                continue
            }

            let type = parserBytes[5]
            let sequence = Self.loadBE32(parserBytes, at: 8)
            let payload = Array(parserBytes[Wire.headerSize..<total])
            parserBytes.removeFirst(total)
            receiveFrameLocked(type: type, sequence: sequence, payload: payload,
                               notifications: &notifications)
        }
    }

    /// Under `lock`.
    private func receiveFrameLocked(type: UInt8, sequence: UInt32, payload: [UInt8],
                                    notifications: inout [(Session, InvalidationReason)]) {
        if type == Wire.hello {
            guard payload.count == Wire.nonceSize else {
                protocolViolationLocked(notifications: &notifications)
                return
            }
            if let replaced = invalidateBackendLocked() {
                notifications.append((replaced, .reset))
            }
            let fresh = makeSessionLocked()
            backendSession = fresh
            expectedGuestSequence = sequence &+ 1
            nextHostSequence = 0
            guard queueFrameLocked(type: Wire.helloAck, payload: payload) else {
                if let invalidated = invalidateLifecycleLocked() {
                    notifications.append((invalidated, .outboundOverflow))
                }
                return
            }
            return
        }

        guard let active = backendSession else { return }
        guard type == Wire.guestReport, payload.count == Report.byteCount,
              sequence == expectedGuestSequence else {
            if let invalidated = invalidateBackendLocked() {
                notifications.append((invalidated, .protocolViolation))
            }
            return
        }
        expectedGuestSequence = sequence &+ 1
        guard inboundReports.count < Self.maximumQueuedReports else {
            if let invalidated = invalidateLifecycleLocked() {
                notifications.append((invalidated, .inboundOverflow))
            }
            return
        }
        inboundReports.append((active, Report(unchecked: payload)))
        scheduleDeliveryLocked()
    }

    /// A corrupt framed candidate invalidates an established backend session;
    /// the byte-wise parser still resynchronizes so a later HELLO can recover.
    /// Under `lock`.
    private func protocolViolationLocked(notifications: inout [(Session, InvalidationReason)]) {
        if let invalidated = invalidateBackendLocked() {
            notifications.append((invalidated, .protocolViolation))
        }
    }

    /// Under `lock`.
    private func scheduleDeliveryLocked() {
        guard !inboundReports.isEmpty, !deliveryScheduled else { return }
        deliveryScheduled = true
        enqueueDelivery()
    }

    /// Called under `lock`, or after a delivery while ownership of the single
    /// scheduled-delivery token is still held.
    private func enqueueDelivery() {
        Task { @MainActor [weak self] in self?.deliverOne() }
    }

    @MainActor
    private func deliverOne() {
        let item = lock.withLock { () -> (Session, Report)? in
            guard !inboundReports.isEmpty else {
                deliveryScheduled = false
                return nil
            }
            return inboundReports.removeFirst()
        }
        if let (expected, report) = item,
           lock.withLock({ backendSession == expected && machine != nil }) {
            delegate?.credentialConsoleBridge(self, received: report, in: expected)
        }
        lock.withLock {
            if inboundReports.isEmpty {
                deliveryScheduled = false
            } else {
                enqueueDelivery()
            }
        }
    }

    // MARK: - Backend to guest

    /// Encodes and queues a host frame, incrementing the host sequence only
    /// after the frame fits. Under `lock`.
    private func queueFrameLocked(type: UInt8, payload: [UInt8]) -> Bool {
        guard let frame = Self.encodeFrame(type: type, sequence: nextHostSequence,
                                           payload: payload) else { return false }
        let pending = outboundStream.count - outboundOffset
        guard pending <= Self.maximumQueuedWireBytes - frame.count else { return false }
        nextHostSequence &+= 1
        outboundStream.append(contentsOf: frame)
        scheduleWriteLocked()
        return true
    }

    /// Under `lock`.
    private func scheduleWriteLocked() {
        guard !writeScheduled, !waitingForInputReady,
              machine != nil, consoleIndex != nil, outboundOffset < outboundStream.count else { return }
        writeScheduled = true
        transportQueue.async { [weak self] in self?.writeOutbound() }
    }

    private func writeOutbound() {
        let invalidated = lock.withLock { () -> Session? in
            writeScheduled = false
            guard lifecycleSession != nil, let machine, let consoleIndex,
                  !waitingForInputReady, outboundOffset < outboundStream.count else { return nil }
            let offered = outboundStream.count - outboundOffset
            let taken = outboundStream.withUnsafeBufferPointer { buffer in
                consoleWriter(machine, consoleIndex,
                              buffer.baseAddress?.advanced(by: outboundOffset), offered)
            }
            guard taken <= offered else { return invalidateLifecycleLocked() }
            outboundOffset += taken
            if outboundOffset == outboundStream.count {
                outboundStream.removeAll(keepingCapacity: true)
                outboundOffset = 0
            } else if outboundOffset >= 4 * Wire.maximumFrameSize {
                outboundStream.removeFirst(outboundOffset)
                outboundOffset = 0
            }
            if taken < offered {
                // crate promises one input_ready callback after this refusal.
                waitingForInputReady = true
            } else {
                scheduleWriteLocked()
            }
            return nil
        }
        if let invalidated { notifyInvalidated(invalidated, because: .invalidConsole) }
    }

    // MARK: - CFD1 framing

    private static func encodeFrame(type: UInt8, sequence: UInt32,
                                    payload: [UInt8]) -> [UInt8]? {
        guard payload.count <= Wire.maximumPayload else { return nil }
        var frame = [UInt8](repeating: 0, count: Wire.headerSize + payload.count)
        frame.replaceSubrange(0..<Wire.magic.count, with: Wire.magic)
        frame[4] = Wire.version
        frame[5] = type
        storeBE16(UInt16(payload.count), in: &frame, at: 6)
        storeBE32(sequence, in: &frame, at: 8)
        if !payload.isEmpty {
            frame.replaceSubrange(Wire.headerSize..<frame.count, with: payload)
        }
        storeBE32(frameCRC(frame, payloadLength: payload.count), in: &frame, at: 12)
        return frame
    }

    private static func frameCRC(_ frame: [UInt8], payloadLength: Int) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        crc = updateCRC(crc, bytes: frame[4..<12])
        if payloadLength != 0 {
            crc = updateCRC(crc, bytes: frame[Wire.headerSize..<(Wire.headerSize + payloadLength)])
        }
        return crc ^ 0xffff_ffff
    }

    private static func updateCRC(_ initial: UInt32, bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc = initial
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xedb8_8320 & mask)
            }
        }
        return crc
    }

    private static func loadBE16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func loadBE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func storeBE16(_ value: UInt16, in bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func storeBE32(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    private func magicOffset(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= Wire.magic.count else { return nil }
        for offset in 0...(bytes.count - Wire.magic.count) {
            if bytes[offset..<(offset + Wire.magic.count)].elementsEqual(Wire.magic) {
                return offset
            }
        }
        return nil
    }

    private func magicPrefixAtEnd(_ bytes: [UInt8]) -> Int {
        let maximum = min(bytes.count, Wire.magic.count - 1)
        guard maximum != 0 else { return 0 }
        for keep in stride(from: maximum, through: 1, by: -1) {
            if bytes.suffix(keep).elementsEqual(Wire.magic.prefix(keep)) { return keep }
        }
        return 0
    }

    // MARK: - Session invalidation

    private func invalidateLifecycle(_ expected: Session, because reason: InvalidationReason) {
        let invalidated = lock.withLock { () -> Session? in
            guard lifecycleSession == expected else { return nil }
            return invalidateLifecycleLocked()
        }
        if let invalidated { notifyInvalidated(invalidated, because: reason) }
    }

    /// Clears the current HELLO binding but leaves the machine stream able to
    /// resynchronize on a later HELLO. Under `lock`.
    private func invalidateBackendLocked() -> Session? {
        let invalidated = backendSession
        backendSession = nil
        expectedGuestSequence = nil
        nextHostSequence = 0
        inboundReports.removeAll(keepingCapacity: true)
        outboundStream.removeAll(keepingCapacity: true)
        outboundOffset = 0
        return invalidated
    }

    /// Under `lock`. Scheduler flags stay set when their one queued worker is
    /// still responsible for clearing them; a new lifecycle can piggyback on
    /// that worker instead of losing a wakeup.
    private func invalidateLifecycleLocked() -> Session? {
        let invalidated = invalidateBackendLocked()
        lifecycleSession = nil
        machine = nil
        consoleIndex = nil
        parserBytes.removeAll(keepingCapacity: true)
        inboundChunks.removeAll(keepingCapacity: true)
        inboundChunkBytes = 0
        waitingForInputReady = false
        return invalidated
    }

    /// Under `lock`.
    private func makeSessionLocked() -> Session {
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        return Session(generation: nextGeneration)
    }

    private func notifyInvalidated(_ invalidated: Session, because reason: InvalidationReason) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.credentialConsoleBridge(self, invalidated: invalidated, because: reason)
        }
    }
}

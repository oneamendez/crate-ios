// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import Security

/// Terminates CTAPHID on the iPhone and forwards only complete, policy-checked
/// CTAP2 messages to a backend such as a USB-CCID YubiKey.
@MainActor @Observable
final class SecurityKeyController: CredentialConsoleBridgeDelegate {
    enum Operation: String, Equatable, Sendable {
        case information = "Checking security key"
        case createPasskey = "Create passkey"
        case signIn = "Sign in"
        case nextAssertion = "Continue sign-in"
        case pin = "Security-key PIN"
        case selection = "Touch security key"
    }

    enum Phase: Equatable, Sendable {
        case waitingForGuest
        case connecting
        case ready(SecurityKeyDevice)
        case request(Operation, relyingParty: String?)
        case failed(String)
    }

    private enum HID {
        static let broadcast: UInt32 = 0xffff_ffff
        static let ping: UInt8 = 0x81
        static let message: UInt8 = 0x83
        static let lock: UInt8 = 0x84
        static let initialize: UInt8 = 0x86
        static let wink: UInt8 = 0x88
        static let cbor: UInt8 = 0x90
        static let cancel: UInt8 = 0x91
        static let keepalive: UInt8 = 0xbb
        static let error: UInt8 = 0xbf

        static let invalidCommand: UInt8 = 0x01
        static let invalidParameter: UInt8 = 0x02
        static let invalidLength: UInt8 = 0x03
        static let invalidSequence: UInt8 = 0x04
        static let messageTimeout: UInt8 = 0x05
        static let channelBusy: UInt8 = 0x06
        static let invalidChannel: UInt8 = 0x0b
    }

    private enum CTAP {
        static let makeCredential: UInt8 = 0x01
        static let getAssertion: UInt8 = 0x02
        static let getInfo: UInt8 = 0x04
        static let clientPIN: UInt8 = 0x06
        static let getNextAssertion: UInt8 = 0x08
        static let selection: UInt8 = 0x0b

        static let invalidCommand: UInt8 = 0x01
        static let operationDenied: UInt8 = 0x27
        static let keepaliveCancel: UInt8 = 0x2d
        static let other: UInt8 = 0x7f

        /// Registration reaches only a backend which explicitly opts in. The
        /// physical YubiKey remains assertion-only at this boundary.
        static let allowed: Set<UInt8> = [
            makeCredential, getAssertion, getInfo, clientPIN,
            getNextAssertion, selection,
        ]
    }

    private struct Assembly {
        let command: UInt8
        let expected: Int
        var bytes: [UInt8]
        var nextSequence: UInt8
        var updated: Date
    }

    private static let maximumMessageBytes = 4 * 1024
    private static let assemblyTimeout: TimeInterval = 3

    private(set) var phase: Phase = .waitingForGuest
    private(set) var device: SecurityKeyDevice?
    private(set) var backendKind: SecurityKeyBackendKind
    private(set) var cratePasskeys: [CratePasskeySummary]

    @ObservationIgnored private let bridge: CredentialConsoleBridge
    @ObservationIgnored private var backend: SecurityKeyBackend
    @ObservationIgnored private var activeSession: CredentialConsoleBridge.Session?
    @ObservationIgnored private var channels = Set<UInt32>()
    @ObservationIgnored private var assemblies: [UInt32: Assembly] = [:]
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var keepaliveTask: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var operationChannel: UInt32?
    @ObservationIgnored private var operationSession: CredentialConsoleBridge.Session?

    init(bridge: CredentialConsoleBridge,
         backend: SecurityKeyBackend? = nil) {
        self.bridge = bridge
        let resolved = backend ?? UnavailableSecurityKeyBackend()
        self.backend = resolved
        backendKind = (resolved as? SecurityKeyBackendRouter)?.kind ?? .yubiKey
        cratePasskeys = (resolved as? SecurityKeyBackendRouter)?.passkeySummaries ?? []
        bridge.delegate = self
    }

    func useBackend(_ replacement: SecurityKeyBackend) {
        cancelOperation(sendStatus: false)
        backend.disconnect()
        backend = replacement
        backendKind = (replacement as? SecurityKeyBackendRouter)?.kind ?? .yubiKey
        refreshCratePasskeys()
        device = nil
        phase = .waitingForGuest
    }

    func selectBackend(_ kind: SecurityKeyBackendKind) {
        guard kind != backendKind,
              let router = backend as? SecurityKeyBackendRouter else { return }
        cancelOperation(sendStatus: false)
        router.select(kind)
        backendKind = kind
        device = nil
        phase = .waitingForGuest
        refreshCratePasskeys()
    }

    func deleteAllCratePasskeys() throws {
        guard let router = backend as? SecurityKeyBackendRouter else { return }
        cancelOperation(sendStatus: false)
        try router.deleteAllCratePasskeys()
        device = nil
        phase = .waitingForGuest
        refreshCratePasskeys()
    }

    /// A phone-side, read-only capability check. This lets the person learn
    /// whether the connected key exposes FIDO2-over-CCID before the Linux
    /// helper is installed; it never creates or changes a credential.
    func connectNow() async {
        guard operationTask == nil else { return }
        if let device {
            phase = .ready(device)
            return
        }
        phase = .connecting
        do {
            let connected = try await backend.connect()
            device = connected
            phase = .ready(connected)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription
                            ?? "The USB security key could not be checked.")
        }
    }

    /// Fail closed when the app backgrounds, the VM stops, or the phone locks.
    func suspend() {
        cancelOperation(sendStatus: false)
        assemblies.removeAll()
        channels.removeAll()
        activeSession = nil
        backend.disconnect()
        device = nil
        phase = .waitingForGuest
    }

    // MARK: - CredentialConsoleBridgeDelegate

    func credentialConsoleBridge(_: CredentialConsoleBridge,
                                 received report: CredentialConsoleBridge.Report,
                                 in session: CredentialConsoleBridge.Session) {
        if activeSession != session {
            reset(for: session)
        }
        take(report.bytes, in: session)
    }

    func credentialConsoleBridge(_: CredentialConsoleBridge,
                                 invalidated session: CredentialConsoleBridge.Session,
                                 because _: CredentialConsoleBridge.InvalidationReason) {
        guard activeSession == session else { return }
        suspend()
    }

    // MARK: - CTAPHID framing

    private func reset(for session: CredentialConsoleBridge.Session) {
        cancelOperation(sendStatus: false)
        backend.disconnect()
        device = nil
        assemblies.removeAll()
        channels.removeAll()
        activeSession = session
        phase = .waitingForGuest
    }

    private func take(_ report: [UInt8], in session: CredentialConsoleBridge.Session) {
        guard report.count == CredentialConsoleBridge.Report.byteCount else { return }
        expireAssemblies(in: session)
        let channel = Self.uint32(report[0..<4])
        guard channel != 0 else { return }
        let marker = report[4]

        if marker & 0x80 != 0 {
            let length = (Int(report[5]) << 8) | Int(report[6])
            guard length <= Self.maximumMessageBytes else {
                sendError(HID.invalidLength, channel: channel, in: session)
                return
            }
            if assemblies.removeValue(forKey: channel) != nil {
                sendError(HID.channelBusy, channel: channel, in: session)
                return
            }
            let first = min(length, 57)
            let bytes = Array(report[7..<(7 + first)])
            if bytes.count == length {
                message(command: marker, payload: bytes, channel: channel, in: session)
            } else {
                assemblies[channel] = Assembly(command: marker, expected: length, bytes: bytes,
                                               nextSequence: 0, updated: Date())
            }
            return
        }

        guard var assembly = assemblies[channel] else {
            sendError(HID.invalidSequence, channel: channel, in: session)
            return
        }
        guard marker == assembly.nextSequence else {
            assemblies.removeValue(forKey: channel)
            sendError(HID.invalidSequence, channel: channel, in: session)
            return
        }
        let remaining = assembly.expected - assembly.bytes.count
        let count = min(remaining, 59)
        assembly.bytes.append(contentsOf: report[5..<(5 + count)])
        assembly.nextSequence &+= 1
        assembly.updated = Date()
        if assembly.bytes.count == assembly.expected {
            assemblies.removeValue(forKey: channel)
            message(command: assembly.command, payload: assembly.bytes, channel: channel, in: session)
        } else if assembly.nextSequence <= 0x7f {
            assemblies[channel] = assembly
        } else {
            assemblies.removeValue(forKey: channel)
            sendError(HID.invalidLength, channel: channel, in: session)
        }
    }

    private func expireAssemblies(in session: CredentialConsoleBridge.Session) {
        let now = Date()
        let expired = assemblies.compactMap { now.timeIntervalSince($0.value.updated) > Self.assemblyTimeout ? $0.key : nil }
        for channel in expired {
            assemblies.removeValue(forKey: channel)
            sendError(HID.messageTimeout, channel: channel, in: session)
        }
    }

    private func message(command: UInt8, payload: [UInt8], channel: UInt32,
                         in session: CredentialConsoleBridge.Session) {
        if command == HID.initialize {
            initialize(payload, channel: channel, in: session)
            return
        }
        guard channels.contains(channel) else {
            sendError(HID.invalidChannel, channel: channel, in: session)
            return
        }

        switch command {
        case HID.ping:
            send(command: HID.ping, payload: payload, channel: channel, in: session)
        case HID.wink:
            guard payload.isEmpty else {
                sendError(HID.invalidLength, channel: channel, in: session)
                return
            }
            send(command: HID.wink, payload: [], channel: channel, in: session)
        case HID.cbor:
            beginCBOR(payload, channel: channel, in: session)
        case HID.cancel:
            guard payload.isEmpty else {
                sendError(HID.invalidLength, channel: channel, in: session)
                return
            }
            if operationChannel == channel { cancelOperation(sendStatus: true) }
        case HID.message, HID.lock:
            sendError(HID.invalidCommand, channel: channel, in: session)
        default:
            sendError(HID.invalidCommand, channel: channel, in: session)
        }
    }

    private func initialize(_ payload: [UInt8], channel: UInt32,
                            in session: CredentialConsoleBridge.Session) {
        guard payload.count == 8 else {
            sendError(HID.invalidLength, channel: channel, in: session)
            return
        }
        let assigned: UInt32
        if channel == HID.broadcast {
            assigned = newChannel()
            channels.insert(assigned)
        } else {
            guard channels.contains(channel) else {
                sendError(HID.invalidChannel, channel: channel, in: session)
                return
            }
            assigned = channel
            if operationChannel == channel { cancelOperation(sendStatus: false) }
            assemblies.removeValue(forKey: channel)
        }

        var response = payload
        response.append(contentsOf: Self.bytes(assigned))
        // CTAPHID protocol 2; device version 1.0.0; CBOR + no legacy MSG.
        response.append(contentsOf: [2, 1, 0, 0, 0x0c])
        send(command: HID.initialize, payload: response, channel: channel, in: session)
    }

    private func newChannel() -> UInt32 {
        while true {
            var candidate: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &candidate) {
                SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
            }
            if status == errSecSuccess, candidate != 0, candidate != HID.broadcast,
               !channels.contains(candidate) {
                return candidate
            }
            candidate = UInt32.random(in: 1..<(HID.broadcast))
            if !channels.contains(candidate) { return candidate }
        }
    }

    // MARK: - CTAP2 backend

    private func beginCBOR(_ payload: [UInt8], channel: UInt32,
                           in session: CredentialConsoleBridge.Session) {
        guard let command = payload.first else {
            send(command: HID.cbor, payload: [CTAP.invalidCommand], channel: channel, in: session)
            return
        }
        guard CTAP.allowed.contains(command),
              command != CTAP.makeCredential
                || backend.capabilities.allowsCredentialCreation else {
            // MakeCredential never reaches an assertion-only physical key.
            // Management, reset and vendor commands remain blocked globally.
            send(command: HID.cbor, payload: [CTAP.invalidCommand], channel: channel, in: session)
            return
        }
        guard operationTask == nil else {
            sendError(HID.channelBusy, channel: channel, in: session)
            return
        }

        let id = UUID()
        operationID = id
        operationChannel = channel
        operationSession = session
        phase = requestPhase(for: Data(payload))
        startKeepalive(id: id, channel: channel, session: session)
        let request = Data(payload)
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.perform(request, id: id, channel: channel, session: session)
        }
    }

    private func perform(_ request: Data, id: UUID, channel: UInt32,
                         session: CredentialConsoleBridge.Session) async {
        do {
            if device == nil {
                phase = .connecting
                device = try await backend.connect()
            }
            phase = requestPhase(for: request)
            let response = try await backend.transact(request)
            try Task.checkCancellation()
            guard operationID == id, operationSession == session else { return }
            guard !response.isEmpty, response.count <= Self.maximumMessageBytes else {
                throw SecurityKeyBackendError.invalidResponse
            }
            send(command: HID.cbor, payload: Array(response), channel: channel, in: session)
            AppLog.write("security key: CTAP command \(request.first ?? 0) completed")
            refreshCratePasskeys()
            finishOperation(id: id, next: device.map(Phase.ready) ?? .waitingForGuest)
        } catch is CancellationError {
            guard operationID == id, operationSession == session else { return }
            send(command: HID.cbor, payload: [CTAP.keepaliveCancel], channel: channel, in: session)
            finishOperation(id: id, next: device.map(Phase.ready) ?? .waitingForGuest)
        } catch {
            guard operationID == id, operationSession == session else { return }
            let status = Self.status(for: error)
            send(command: HID.cbor, payload: [status], channel: channel, in: session)
            let message = (error as? LocalizedError)?.errorDescription ?? "The security key could not complete the request."
            AppLog.write("security key: CTAP command \(request.first ?? 0) failed")
            finishOperation(id: id, next: .failed(message))
        }
    }

    private func startKeepalive(id: UUID, channel: UInt32,
                                session: CredentialConsoleBridge.Session) {
        keepaliveTask = Task { [weak self] in
            var ticks = 0
            while true {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.operationID == id, self.operationSession == session else { return }
                ticks += 1
                // PROCESSING initially, then UPNEEDED while a person may be
                // entering a PIN or touching the key.
                self.send(command: HID.keepalive, payload: [ticks < 4 ? 0x01 : 0x02],
                          channel: channel, in: session)
            }
        }
    }

    private func cancelOperation(sendStatus: Bool) {
        if sendStatus, let channel = operationChannel, let session = operationSession {
            send(command: HID.cbor, payload: [CTAP.keepaliveCancel], channel: channel, in: session)
        }
        operationID = nil
        operationChannel = nil
        operationSession = nil
        operationTask?.cancel()
        operationTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        backend.cancel()
        phase = device.map(Phase.ready) ?? .waitingForGuest
    }

    private func finishOperation(id: UUID, next: Phase) {
        guard operationID == id else { return }
        operationID = nil
        operationChannel = nil
        operationSession = nil
        operationTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        phase = next
    }

    private func requestPhase(for request: Data) -> Phase {
        guard let command = request.first else { return .failed("The guest sent an empty security-key request.") }
        switch command {
        case CTAP.makeCredential:
            return .request(.createPasskey, relyingParty: relyingParty(in: request))
        case CTAP.getInfo:
            return .request(.information, relyingParty: nil)
        case CTAP.getAssertion:
            return .request(.signIn, relyingParty: relyingParty(in: request))
        case CTAP.getNextAssertion:
            return .request(.nextAssertion, relyingParty: nil)
        case CTAP.clientPIN:
            return .request(.pin, relyingParty: nil)
        case CTAP.selection:
            return .request(.selection, relyingParty: nil)
        default:
            return .failed("Crate blocked an unsupported security-key operation.")
        }
    }

    private func relyingParty(in request: Data) -> String? {
        CratePasskeyProtocol.displayableRelyingPartyID(in: request)
            ?? YubiKeyCTAPRequestPolicy.displayableRelyingPartyID(in: request)
    }

    private func refreshCratePasskeys() {
        cratePasskeys = (backend as? SecurityKeyBackendRouter)?.passkeySummaries ?? []
    }

    private static func status(for error: Error) -> UInt8 {
        guard let error = error as? SecurityKeyBackendError else { return CTAP.other }
        switch error {
        case .cancelled, .timedOut: return CTAP.keepaliveCancel
        case .denied: return CTAP.operationDenied
        case .unsupported: return CTAP.invalidCommand
        case .unavailable, .disconnected, .invalidResponse: return CTAP.other
        }
    }

    // MARK: - Host to guest reports

    private func sendError(_ code: UInt8, channel: UInt32,
                           in session: CredentialConsoleBridge.Session) {
        send(command: HID.error, payload: [code], channel: channel, in: session)
    }

    private func send(command: UInt8, payload: [UInt8], channel: UInt32,
                      in session: CredentialConsoleBridge.Session) {
        guard payload.count <= Self.maximumMessageBytes,
              payload.count <= Int(UInt16.max) else { return }
        var remaining = payload[...]
        var first = Self.bytes(channel)
        first.append(command)
        first.append(UInt8(payload.count >> 8))
        first.append(UInt8(payload.count & 0xff))
        let initial = remaining.prefix(57)
        first.append(contentsOf: initial)
        remaining = remaining.dropFirst(initial.count)
        first.append(contentsOf: repeatElement(0, count: 64 - first.count))
        guard sendReport(first, in: session) else { return }

        var sequence: UInt8 = 0
        while !remaining.isEmpty {
            var continuation = Self.bytes(channel)
            continuation.append(sequence)
            let part = remaining.prefix(59)
            continuation.append(contentsOf: part)
            remaining = remaining.dropFirst(part.count)
            continuation.append(contentsOf: repeatElement(0, count: 64 - continuation.count))
            guard sendReport(continuation, in: session) else { return }
            sequence &+= 1
        }
    }

    private func sendReport(_ bytes: [UInt8],
                            in session: CredentialConsoleBridge.Session) -> Bool {
        guard let report = CredentialConsoleBridge.Report(bytes) else { return false }
        switch bridge.send(report, in: session) {
        case .accepted:
            return true
        case .staleSession, .notAttached, .queueFull:
            if activeSession == session { suspend() }
            return false
        }
    }

    private static func uint32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff),
         UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
}

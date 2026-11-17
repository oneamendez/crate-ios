// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import UIKit
import YubiKit

enum YubiKeyTransport: Equatable, Sendable {
    case usb
    case nfc

    var title: String {
        switch self {
        case .usb: "USB-C YubiKey"
        case .nfc: "NFC YubiKey"
        }
    }

    var unavailableReason: String {
        switch self {
        case .usb: "No supported USB-C YubiKey is connected."
        case .nfc: "No NFC YubiKey session is active."
        }
    }
}

/// Assertion-only CTAP2 over YubiKit's public smart-card connections. USB-C
/// uses CryptoTokenKit/CCID and therefore needs YubiKey 5.8 or newer; NFC uses
/// ISO 7816 and supports the user's 5.7 key. Neither path is raw passthrough:
/// the guest can submit only requests accepted by `YubiKeyCTAPRequestPolicy`.
@MainActor
final class YubiKeySecurityKeyBackend: SecurityKeyBackend {
    private static let minimumCCIDFIDOVersion = Version("5.8.0")!
    private static let maximumResponseBytes = 64 * 1024
    private static let maximumContinuationCount = 256
    private static let maximumKeepalivePollCount = 1_200
    private static let operationTimeout: TimeInterval = 120

    private let transport: YubiKeyTransport
    private var connection: (any SmartCardConnection)?
    private var connectedDevice: SecurityKeyDevice?
    private var maximumMessageBytes = YubiKeyCTAPRequestPolicy.hardMaximumRequestBytes
    private var connectionGeneration: UInt64 = 0
    private var isConnecting = false
    private var activeOperation: UUID?
    private var cancelRequested = false
    private var mayRequestNextAssertion = false
    private var scopedPINRelyingPartyID: String?
    private var connectionWatchTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []

    private(set) var capability: YubiKeyCapability

    init(transport: YubiKeyTransport = .usb,
         monitorsApplicationLifecycle: Bool = true) {
        self.transport = transport
        capability = .unavailable(reason: transport.unavailableReason)
        // YubiKit's DEBUG trace logging can contain complete APDUs. Keep the
        // package at critical for this process so reports, PIN protocol data,
        // credential identifiers, and assertion material are never logged.
        YubiKit.Logs.configure(logLevel: .critical)

        guard monitorsApplicationLifecycle else { return }
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            lifecycleObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.disconnect()
                    }
                }
            )
        }
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let connection {
            Task { await connection.close(error: nil) }
        }
    }

    func connect() async throws -> SecurityKeyDevice {
        if let connectedDevice, connection != nil {
            return connectedDevice
        }
        guard !isConnecting else {
            throw SecurityKeyBackendError.unavailable("A YubiKey connection is already being opened.")
        }
        guard activeOperation == nil else {
            throw SecurityKeyBackendError.unavailable("A security-key request is still finishing.")
        }

        isConnecting = true
        let expectedGeneration = connectionGeneration
        defer { isConnecting = false }

        do {
            let opened = try await openReadOnly()
            guard connectionGeneration == expectedGeneration else {
                await opened.connection.close(error: nil)
                throw SecurityKeyBackendError.cancelled
            }

            connection = opened.connection
            connectedDevice = opened.device
            maximumMessageBytes = opened.maximumMessageBytes
            mayRequestNextAssertion = false
            scopedPINRelyingPartyID = nil
            cancelRequested = false
            capability = .available(
                device: opened.device,
                firmware: opened.firmware,
                maximumMessageBytes: opened.maximumMessageBytes
            )
            watchForDisconnect(opened.connection, generation: expectedGeneration)
            return opened.device
        } catch let error as SecurityKeyBackendError {
            switch error {
            case .unsupported(let reason):
                capability = .unsupported(reason: reason)
            case .unavailable(let reason):
                capability = .unavailable(reason: reason)
            default:
                break
            }
            throw error
        } catch {
            let reason: String
            switch transport {
            case .usb:
                reason = "The USB security key could not be opened through CryptoTokenKit."
            case .nfc:
                reason = "The NFC security-key session could not be opened."
            }
            capability = .unavailable(reason: reason)
            throw SecurityKeyBackendError.unavailable(reason)
        }
    }

    func transact(_ request: Data) async throws -> Data {
        guard let connection else { throw SecurityKeyBackendError.disconnected }
        guard activeOperation == nil else {
            throw SecurityKeyBackendError.unavailable("Another security-key request is already in progress.")
        }

        let decision: YubiKeyCTAPRequestPolicy.Decision
        do {
            decision = try YubiKeyCTAPRequestPolicy.validate(
                request,
                maximumBytes: maximumMessageBytes
            )
        } catch {
            throw SecurityKeyBackendError.denied
        }

        try enforceSequence(for: decision)

        let operation = UUID()
        let generation = connectionGeneration
        activeOperation = operation
        cancelRequested = false
        if case .getNextAssertion = decision {
            // A failed or final getNextAssertion must not leave a stale permit.
            mayRequestNextAssertion = false
        } else if case .getAssertion = decision {
            mayRequestNextAssertion = false
        } else {
            // CTAP requires getNextAssertion to immediately follow the previous
            // assertion; any other command closes that window.
            mayRequestNextAssertion = false
        }

        defer {
            if activeOperation == operation {
                activeOperation = nil
                cancelRequested = false
            }
        }

        let response = try await perform(
            request,
            using: connection,
            generation: generation
        )
        guard connectionGeneration == generation, self.connection != nil else {
            throw SecurityKeyBackendError.disconnected
        }

        let succeeded = response.first == 0x00
        if succeeded {
            switch decision {
            case .getAssertion:
                mayRequestNextAssertion = true
            case .getNextAssertion:
                // The authenticator will return an error on the first request
                // after the final assertion, which closes this permit.
                mayRequestNextAssertion = true
            case .clientPIN(.getAssertionToken(let relyingPartyID)):
                scopedPINRelyingPartyID = relyingPartyID
            default:
                break
            }
        }
        return response
    }

    func cancel() {
        guard activeOperation != nil else { return }
        cancelRequested = true
    }

    func disconnect() {
        let closing = takeConnectionForDisconnect()
        if let closing {
            Task { await closing.close(error: nil) }
        }
    }

    /// Used by the standalone capability probe so a subsequent real connect
    /// cannot race YubiKit's single-connection teardown.
    func disconnectAndWait() async {
        let closing = takeConnectionForDisconnect()
        if let closing {
            await closing.close(error: nil)
        }
    }

    private func takeConnectionForDisconnect() -> (any SmartCardConnection)? {
        connectionGeneration &+= 1
        cancelRequested = true
        mayRequestNextAssertion = false
        scopedPINRelyingPartyID = nil
        maximumMessageBytes = YubiKeyCTAPRequestPolicy.hardMaximumRequestBytes
        connectedDevice = nil
        capability = .unavailable(reason: transport.unavailableReason)

        connectionWatchTask?.cancel()
        connectionWatchTask = nil
        let closing = connection
        connection = nil
        return closing
    }

    private func enforceSequence(for decision: YubiKeyCTAPRequestPolicy.Decision) throws {
        switch decision {
        case .getNextAssertion:
            guard mayRequestNextAssertion else { throw SecurityKeyBackendError.denied }
        case .getAssertion(let relyingPartyID, let usesPINUVAuth):
            if usesPINUVAuth, let scopedPINRelyingPartyID,
               scopedPINRelyingPartyID != relyingPartyID {
                throw SecurityKeyBackendError.denied
            }
        default:
            break
        }
    }

    private struct OpenedConnection {
        let connection: any SmartCardConnection
        let device: SecurityKeyDevice
        let firmware: String?
        let maximumMessageBytes: Int
    }

    private func openReadOnly() async throws -> OpenedConnection {
        let opened = try await openTransport()

        do {
            var firmware: Version?
            // The management applet is needed only to gate the USB/CCID path
            // by firmware version. Selecting it first over NFC needlessly
            // switches applets before the FIDO session and can leave older
            // 5.x keys unable to answer the following CTAP GetInfo command.
            // Go directly to the FIDO applet for NFC instead.
            if transport == .usb,
               let management = try? await Management.Session.makeSession(connection: opened) {
                firmware = await management.version
            }
            if transport == .usb, let firmware, firmware < Self.minimumCCIDFIDOVersion {
                throw SecurityKeyBackendError.unsupported(
                    "This YubiKey has firmware \(firmware). Crate's iOS USB path needs FIDO2 over smart card, which starts at firmware 5.8. YubiKey firmware cannot be upgraded; choose NFC YubiKey or Crate Passkeys instead."
                )
            }

            do {
                _ = try await CTAP2.Session.makeSession(connection: opened)
            } catch {
                let detail = transport == .usb
                    ? "That USB transport starts with YubiKey firmware 5.8; choose NFC for an older NFC-capable key."
                    : "Make sure NFC is enabled on the key and hold it against the top of the iPhone."
                throw SecurityKeyBackendError.unsupported(
                    "This key did not expose FIDO2 over \(transport == .usb ? "USB smart card" : "NFC"). \(detail)"
                )
            }

            let getInfoResponse: Data
            do {
                // YubiKit 1.4's generic APDU encoder omits the trailing Le
                // byte. CTAP's NFC framing defines Le as part of NFCCTAP_MSG,
                // and firmware 5.7 rejects the otherwise valid GetInfo APDU.
                // Keep YubiKit's application selection, then use Crate's
                // spec-correct read-only transport for the probe itself.
                getInfoResponse = try await perform(
                    Data([0x04]),
                    using: opened,
                    generation: connectionGeneration
                )
            } catch {
                throw SecurityKeyBackendError.unsupported(
                    "The key's FIDO2 application did not answer a read-only GetInfo request."
                )
            }

            guard getInfoResponse.first == 0x00 else {
                throw SecurityKeyBackendError.invalidResponse
            }
            let info: CBOR
            do {
                info = try CBOR.decode(Data(getInfoResponse.dropFirst()))
            } catch {
                throw SecurityKeyBackendError.invalidResponse
            }
            guard
                let versions = info.value(forUnsigned: 0x01)?.arrayValue,
                !versions.isEmpty,
                versions.allSatisfy({ $0.textValue != nil }),
                info.value(forUnsigned: 0x03)?.bytesValue?.count == 16,
                info.value(forUnsigned: 0x04)?.mapValue != nil
            else {
                throw SecurityKeyBackendError.invalidResponse
            }
            let advertisedMaximum: UInt64
            if let encodedMaximum = info.value(forUnsigned: 0x05) {
                guard case .unsigned(let value) = encodedMaximum else {
                    throw SecurityKeyBackendError.invalidResponse
                }
                advertisedMaximum = value
            } else {
                advertisedMaximum = 1_024
            }
            let reportedMaximum = min(
                advertisedMaximum,
                UInt64(YubiKeyCTAPRequestPolicy.hardMaximumRequestBytes)
            )
            guard reportedMaximum > 0 else { throw SecurityKeyBackendError.invalidResponse }
            let maximum = Int(reportedMaximum)
            let firmwareText = firmware?.description
            let transportDetail = transport == .usb ? "FIDO2 over USB smart card" : "FIDO2 over NFC"
            let detail = firmwareText.map { "Firmware \($0); \(transportDetail)" }
                ?? transportDetail
            return OpenedConnection(
                connection: opened,
                device: SecurityKeyDevice(name: transport.title, detail: detail),
                firmware: firmwareText,
                maximumMessageBytes: maximum
            )
        } catch {
            await opened.close(error: nil)
            throw error
        }
    }

    private func openTransport() async throws -> any SmartCardConnection {
        if transport == .nfc {
            do {
                return try await NFCSmartCardConnection(
                    alertMessage: "Hold your YubiKey near the top of this iPhone."
                )
            } catch {
                throw SecurityKeyBackendError.unavailable(
                    "NFC YubiKey reading is unavailable. Crate needs Apple's NFC Tag Reading capability in its signing profile."
                )
            }
        }

        let slots: [USBSmartCard.YubiKeyDevice]
        do {
            slots = try await USBSmartCardConnection.availableDevices()
        } catch {
            throw SecurityKeyBackendError.unavailable(
                "USB smart-card access is unavailable. Reconnect the YubiKey and verify iOS sees its CCID interface."
            )
        }
        guard let slot = slots.first else {
            throw SecurityKeyBackendError.unavailable(
                "Plug in a YubiKey 5.8 or newer with its USB smart-card interface enabled."
            )
        }

        do {
            return try await USBSmartCardConnection.makeConnection(slot: slot)
        } catch {
            throw SecurityKeyBackendError.unavailable(
                "The YubiKey smart-card interface is busy or no longer connected."
            )
        }
    }

    private func watchForDisconnect(_ connection: any SmartCardConnection, generation: UInt64) {
        connectionWatchTask?.cancel()
        connectionWatchTask = Task { [weak self] in
            _ = await connection.waitUntilClosed()
            guard !Task.isCancelled else { return }
            self?.connectionDidClose(generation: generation)
        }
    }

    private func connectionDidClose(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        connectionGeneration &+= 1
        connection = nil
        connectedDevice = nil
        cancelRequested = true
        mayRequestNextAssertion = false
        scopedPINRelyingPartyID = nil
        maximumMessageBytes = YubiKeyCTAPRequestPolicy.hardMaximumRequestBytes
        capability = .unavailable(reason: "The \(transport.title) was disconnected.")
        connectionWatchTask = nil
    }

    private struct APDUResponse {
        let data: Data
        let status: UInt16
    }

    private func perform(
        _ request: Data,
        using connection: any SmartCardConnection,
        generation: UInt64
    ) async throws -> Data {
        guard !cancelRequested else { throw SecurityKeyBackendError.cancelled }

        let initial = try makeAPDU(
            cla: 0x80,
            ins: 0x10,
            p1: 0x80,
            p2: 0x00,
            command: request
        )
        var response = try await exchange(initial, using: connection)
        guard connectionGeneration == generation else { throw SecurityKeyBackendError.disconnected }

        let deadline = Date().addingTimeInterval(Self.operationTimeout)
        var keepalivePollCount = 0
        while response.status == 0x9100 {
            if Date() >= deadline || keepalivePollCount >= Self.maximumKeepalivePollCount {
                let cancelPoll = try makeAPDU(cla: 0x80, ins: 0x11, p1: 0x11, p2: 0x00)
                _ = try? await exchange(cancelPoll, using: connection)
                throw SecurityKeyBackendError.timedOut
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
            keepalivePollCount += 1
            guard connectionGeneration == generation else { throw SecurityKeyBackendError.disconnected }

            let cancelling = cancelRequested || Task.isCancelled
            let poll = try makeAPDU(
                cla: 0x80,
                ins: 0x11,
                p1: cancelling ? 0x11 : 0x00,
                p2: 0x00
            )
            response = try await exchange(poll, using: connection)
            guard connectionGeneration == generation else { throw SecurityKeyBackendError.disconnected }
            if cancelling { throw SecurityKeyBackendError.cancelled }
        }

        guard response.status == 0x9000, !response.data.isEmpty,
              response.data.count <= Self.maximumResponseBytes else {
            throw SecurityKeyBackendError.invalidResponse
        }
        if cancelRequested || Task.isCancelled {
            throw SecurityKeyBackendError.cancelled
        }
        return response.data
    }

    private func exchange(
        _ command: Data,
        using connection: any SmartCardConnection
    ) async throws -> APDUResponse {
        var nextCommand = command
        var accumulated = Data()
        var continuationCount = 0

        while true {
            let raw: Data
            do {
                raw = try await connection.send(data: nextCommand)
            } catch {
                throw SecurityKeyBackendError.disconnected
            }
            guard raw.count >= 2 else { throw SecurityKeyBackendError.invalidResponse }

            let payloadCount = raw.count - 2
            accumulated.append(raw.prefix(payloadCount))
            guard accumulated.count <= Self.maximumResponseBytes else {
                throw SecurityKeyBackendError.invalidResponse
            }

            let sw1 = raw[payloadCount]
            let sw2 = raw[payloadCount + 1]
            if sw1 != 0x61 {
                return APDUResponse(
                    data: accumulated,
                    status: (UInt16(sw1) << 8) | UInt16(sw2)
                )
            }

            continuationCount += 1
            guard continuationCount <= Self.maximumContinuationCount else {
                throw SecurityKeyBackendError.invalidResponse
            }
            // Match YubiKit's public smart-card implementation: GET RESPONSE,
            // Le=0, accumulating until the card stops returning SW1=0x61.
            nextCommand = Data([0x00, 0xc0, 0x00, 0x00, 0x00])
        }
    }

    private func makeAPDU(
        cla: UInt8,
        ins: UInt8,
        p1: UInt8,
        p2: UInt8,
        command: Data? = nil
    ) throws -> Data {
        var result = Data([cla, ins, p1, p2])
        guard let command, !command.isEmpty else { return result }
        guard command.count <= Int(UInt16.max) else { throw SecurityKeyBackendError.denied }

        if command.count < Int(UInt8.max) {
            result.append(UInt8(command.count))
        } else {
            let length = UInt16(command.count)
            result.append(0x00)
            result.append(UInt8(length >> 8))
            result.append(UInt8(length & 0xff))
        }
        result.append(command)
        // NFCCTAP_MSG is an ISO 7816 case-4 command. Le=0 asks for the
        // maximum response size (256 bytes for a short APDU, 65,536 for an
        // extended APDU); larger replies continue through SW1=0x61.
        if command.count < Int(UInt8.max) {
            result.append(0x00)
        } else {
            result.append(contentsOf: [0x00, 0x00])
        }
        return result
    }
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum SecurityKeyBackendKind: String, CaseIterable, Identifiable, Sendable {
    case cratePasskeys
    case yubiKey
    case yubiKeyNFC

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cratePasskeys: "Crate Passkeys"
        case .yubiKey: "USB-C YubiKey"
        case .yubiKeyNFC: "NFC YubiKey"
        }
    }

    var shortTitle: String {
        switch self {
        case .cratePasskeys: "Face ID"
        case .yubiKey: "USB"
        case .yubiKeyNFC: "NFC"
        }
    }

    var symbol: String {
        switch self {
        case .cratePasskeys: "faceid"
        case .yubiKey: "key.horizontal"
        case .yubiKeyNFC: "wave.3.right"
        }
    }

    /// The unsigned release contains the NFC implementation, but the signing
    /// script exposes it only when the selected profile grants NFC Tag
    /// Reading. That prevents a build signed with an older profile from
    /// presenting a button the system must reject.
    static var availableCases: [Self] {
        var result: [Self] = [.cratePasskeys, .yubiKey]
        if Bundle.main.object(forInfoDictionaryKey: "CrateNFCYubiKeyEnabled") as? Bool == true {
            result.append(.yubiKeyNFC)
        }
        return result
    }
}

/// Keeps the phone-owned and physical authenticators completely separate.
/// Switching disconnects the previous backend before another request can be
/// accepted, and the narrow YubiKey policy remains unchanged.
@MainActor
final class SecurityKeyBackendRouter: SecurityKeyBackend {
    private static let defaultsKey = "securityKeyBackendKind"

    private let defaults: UserDefaults
    private let cratePasskeys: CratePasskeySecurityKeyBackend
    private let yubiKey: YubiKeySecurityKeyBackend
    private let nfcYubiKey: YubiKeySecurityKeyBackend
    private(set) var kind: SecurityKeyBackendKind

    init(defaults: UserDefaults = .standard,
         cratePasskeys: CratePasskeySecurityKeyBackend? = nil,
         yubiKey: YubiKeySecurityKeyBackend? = nil,
         nfcYubiKey: YubiKeySecurityKeyBackend? = nil) {
        self.defaults = defaults
        self.cratePasskeys = cratePasskeys ?? CratePasskeySecurityKeyBackend()
        self.yubiKey = yubiKey ?? YubiKeySecurityKeyBackend(transport: .usb)
        self.nfcYubiKey = nfcYubiKey ?? YubiKeySecurityKeyBackend(transport: .nfc)
        let saved = defaults.string(forKey: Self.defaultsKey)
            .flatMap(SecurityKeyBackendKind.init(rawValue:))
        kind = saved.flatMap { SecurityKeyBackendKind.availableCases.contains($0) ? $0 : nil }
            ?? .cratePasskeys
    }

    var capabilities: SecurityKeyBackendCapabilities {
        selected.capabilities
    }

    var passkeySummaries: [CratePasskeySummary] {
        cratePasskeys.credentialSummaries
    }

    func select(_ replacement: SecurityKeyBackendKind) {
        guard replacement != kind else { return }
        selected.disconnect()
        kind = replacement
        defaults.set(replacement.rawValue, forKey: Self.defaultsKey)
    }

    func connect() async throws -> SecurityKeyDevice {
        try await selected.connect()
    }

    func transact(_ request: Data) async throws -> Data {
        try await selected.transact(request)
    }

    func cancel() {
        selected.cancel()
    }

    func disconnect() {
        selected.disconnect()
    }

    func deleteAllCratePasskeys() throws {
        try cratePasskeys.deleteAllCredentials()
    }

    private var selected: SecurityKeyBackend {
        switch kind {
        case .cratePasskeys: cratePasskeys
        case .yubiKey: yubiKey
        case .yubiKeyNFC: nfcYubiKey
        }
    }
}

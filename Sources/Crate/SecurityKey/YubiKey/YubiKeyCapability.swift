// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Read-only result of probing the supported USB smart-card path. It contains
/// no slot name, serial number, credential identifier, PIN, or key material.
enum YubiKeyCapability: Equatable, Sendable {
    case unavailable(reason: String)
    case unsupported(reason: String)
    case available(device: SecurityKeyDevice, firmware: String?, maximumMessageBytes: Int)
}

@MainActor
enum YubiKeyCapabilityProbe {
    /// Opens the key, selects its management and FIDO applications, performs
    /// CTAP GetInfo, then closes it. Every operation is read-only.
    static func probe() async -> YubiKeyCapability {
        let backend = YubiKeySecurityKeyBackend(monitorsApplicationLifecycle: false)
        do {
            _ = try await backend.connect()
            let result = backend.capability
            await backend.disconnectAndWait()
            return result
        } catch let error as SecurityKeyBackendError {
            await backend.disconnectAndWait()
            switch error {
            case .unsupported(let reason):
                return .unsupported(reason: reason)
            case .unavailable(let reason):
                return .unavailable(reason: reason)
            default:
                return .unavailable(reason: error.localizedDescription)
            }
        } catch {
            await backend.disconnectAndWait()
            return .unavailable(reason: "The USB security key could not be probed.")
        }
    }
}

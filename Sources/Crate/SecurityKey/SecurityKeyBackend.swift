// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct SecurityKeyDevice: Equatable, Sendable {
    let name: String
    let detail: String?
}

struct SecurityKeyBackendCapabilities: Equatable, Sendable {
    let allowsCredentialCreation: Bool

    static let assertionOnly = SecurityKeyBackendCapabilities(
        allowsCredentialCreation: false
    )
}

/// A CTAP2 authenticator behind Crate's CTAPHID transport.
///
/// Requests begin with the one-byte CTAP2 command and responses begin with the
/// one-byte CTAP status. Implementations may translate to another physical
/// transport (the USB-CCID YubiKey backend) or use a phone-held key, but never
/// expose raw secrets to the guest.
@MainActor
protocol SecurityKeyBackend: AnyObject {
    /// Physical keys stay assertion-only. A phone-owned authenticator may opt
    /// in to MakeCredential after implementing its own storage and consent UI.
    var capabilities: SecurityKeyBackendCapabilities { get }
    /// Opens/probes the device without changing credentials or configuration.
    func connect() async throws -> SecurityKeyDevice
    /// One complete CTAP2 request/response. Maximum size is enforced again by
    /// the CTAPHID controller at the VM boundary.
    func transact(_ request: Data) async throws -> Data
    /// Cancels an operation waiting for touch/PIN if the backend supports it.
    func cancel()
    /// Drops transport/PIN-token state on VM stop, background, or unplug.
    func disconnect()
}

extension SecurityKeyBackend {
    var capabilities: SecurityKeyBackendCapabilities { .assertionOnly }
}

enum SecurityKeyBackendError: LocalizedError, Equatable {
    case unavailable(String)
    case unsupported(String)
    case disconnected
    case cancelled
    case invalidResponse
    case denied
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .unsupported(let reason): reason
        case .disconnected: "The security key was disconnected."
        case .cancelled: "The security-key request was cancelled."
        case .invalidResponse: "The security key returned an invalid response."
        case .denied: "The security-key request was denied."
        case .timedOut: "The security-key request timed out."
        }
    }
}

@MainActor
final class UnavailableSecurityKeyBackend: SecurityKeyBackend {
    private let reason: String

    init(_ reason: String = "No supported security key is connected.") {
        self.reason = reason
    }

    func connect() async throws -> SecurityKeyDevice {
        throw SecurityKeyBackendError.unavailable(reason)
    }

    func transact(_: Data) async throws -> Data {
        throw SecurityKeyBackendError.unavailable(reason)
    }

    func cancel() {}
    func disconnect() {}
}

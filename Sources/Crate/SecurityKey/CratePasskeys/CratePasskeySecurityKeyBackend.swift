// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import LocalAuthentication
import Security

/// A CTAP2 authenticator whose P-256 private keys live in this phone's Secure
/// Enclave. It is intentionally distinct from Apple Passwords: credentials do
/// not sync or leave this device, and each creation/assertion requires device
/// authentication before the key can be used.
@MainActor
final class CratePasskeySecurityKeyBackend: SecurityKeyBackend {
    private struct PendingAssertions {
        var responses: [Data]
        let expiresAt: Date
    }

    private let store: CratePasskeyStore
    private let keys: CratePasskeyKeyProvider
    private var pendingAssertions: PendingAssertions?

    init(store: CratePasskeyStore? = nil,
         keys: CratePasskeyKeyProvider? = nil) {
        self.store = store ?? CratePasskeyStore()
        self.keys = keys ?? CratePasskeyKeyProvider()
    }

    var capabilities: SecurityKeyBackendCapabilities {
        .init(allowsCredentialCreation: true)
    }

    var credentialSummaries: [CratePasskeySummary] {
        (try? store.load())?
            .map(CratePasskeySummary.init)
            .sorted {
                if $0.relyingPartyID == $1.relyingPartyID {
                    return $0.createdAt > $1.createdAt
                }
                return $0.relyingPartyID < $1.relyingPartyID
            } ?? []
    }

    func connect() async throws -> SecurityKeyDevice {
        try keys.checkAvailability()
        let count = try store.load().count
        let authentication = keys.authenticationDescription
        return SecurityKeyDevice(
            name: "Crate Passkeys",
            detail: "\(authentication); \(count) device-only passkey\(count == 1 ? "" : "s")"
        )
    }

    func transact(_ request: Data) async throws -> Data {
        let command: CratePasskeyProtocol.Command
        do {
            command = try CratePasskeyProtocol.decode(request)
        } catch let status as CratePasskeyProtocol.Status {
            return CratePasskeyProtocol.response(status: status)
        } catch {
            return CratePasskeyProtocol.response(status: .invalidCBOR)
        }

        if case .getNextAssertion = command {
            // GetNextAssertion consumes the state established below.
        } else {
            pendingAssertions = nil
        }

        switch command {
        case .getInfo:
            return CratePasskeyProtocol.getInfoResponse()
        case .makeCredential(let request):
            return try await makeCredential(request)
        case .getAssertion(let request):
            return try await getAssertion(request)
        case .getNextAssertion:
            return nextAssertion()
        case .selection:
            _ = try await keys.authenticate(reason: "Use Crate Passkeys from Linux")
            return Data([0x00])
        }
    }

    func cancel() {
        keys.cancel()
        pendingAssertions = nil
    }

    func disconnect() {
        cancel()
    }

    func deleteAllCredentials() throws {
        let records = try store.load()
        // Remove the index first. A failed Secure Enclave deletion can leave
        // an unreachable key, but can never leave a usable credential record.
        try store.save([])
        for record in records { keys.deleteKey(tag: record.keyTag) }
        pendingAssertions = nil
    }

    private func makeCredential(
        _ request: CratePasskeyProtocol.MakeCredentialRequest
    ) async throws -> Data {
        var records = try store.load()
        let excluded = Set(request.excludedCredentialIDs)
        let hasExcludedCredential = records.contains {
            $0.relyingPartyID == request.relyingPartyID
                && excluded.contains($0.credentialID)
        }

        let account = request.userName ?? request.userDisplayName
        let reason = account.map {
            "Create a passkey for \($0) at \(request.relyingPartyID)"
        } ?? "Create a passkey for \(request.relyingPartyID)"
        let context = try await keys.authenticate(reason: reason)
        if hasExcludedCredential {
            return CratePasskeyProtocol.response(status: .credentialExcluded)
        }

        let replaced: [CratePasskeyCredentialRecord]
        if request.discoverable {
            replaced = records.filter {
                $0.discoverable
                    && $0.relyingPartyID == request.relyingPartyID
                    && $0.userID == request.userID
            }
            let replacedIDs = Set(replaced.map(\.credentialID))
            records.removeAll { replacedIDs.contains($0.credentialID) }
        } else {
            replaced = []
        }
        guard records.count < CratePasskeyProtocol.maximumCredentialCount else {
            return CratePasskeyProtocol.response(status: .keyStoreFull)
        }

        let credentialID = try uniqueRandomCredentialID(existing: records)
        let keyTag = Data(
            "\((Bundle.main.bundleIdentifier ?? "crate")).passkey.\(UUID().uuidString)".utf8
        )
        let coordinates = try keys.createKey(tag: keyTag, context: context)
        let record = CratePasskeyCredentialRecord(
            credentialID: credentialID,
            keyTag: keyTag,
            relyingPartyID: request.relyingPartyID,
            userID: request.userID,
            userName: request.userName,
            userDisplayName: request.userDisplayName,
            discoverable: request.discoverable,
            createdAt: .now
        )

        do {
            records.append(record)
            try store.save(records)
        } catch {
            keys.deleteKey(tag: keyTag)
            throw error
        }
        for old in replaced { keys.deleteKey(tag: old.keyTag) }

        do {
            return try CratePasskeyProtocol.makeCredentialResponse(
                relyingPartyID: request.relyingPartyID,
                credentialID: credentialID,
                publicKeyX: coordinates.x,
                publicKeyY: coordinates.y
            )
        } catch {
            // A response-assembly failure must not strand a credential that the
            // website never received.
            records.removeAll { $0.credentialID == credentialID }
            try? store.save(records)
            keys.deleteKey(tag: keyTag)
            throw error
        }
    }

    private func getAssertion(
        _ request: CratePasskeyProtocol.GetAssertionRequest
    ) async throws -> Data {
        let records = try store.load()
        let matches: [CratePasskeyCredentialRecord]
        if let allowed = request.allowedCredentialIDs {
            let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.credentialID, $0) })
            var seen = Set<Data>()
            matches = allowed.compactMap { identifier in
                guard seen.insert(identifier).inserted,
                      let record = byID[identifier],
                      record.relyingPartyID == request.relyingPartyID else { return nil }
                return record
            }
        } else {
            matches = records.filter {
                $0.discoverable && $0.relyingPartyID == request.relyingPartyID
            }
        }
        guard !matches.isEmpty else {
            return CratePasskeyProtocol.response(status: .noCredentials)
        }

        let context = try await keys.authenticate(
            reason: "Sign in to \(request.relyingPartyID) with Crate Passkeys"
        )
        let authenticatorData = CratePasskeyProtocol.assertionAuthenticatorData(
            relyingPartyID: request.relyingPartyID,
            userPresent: request.requiresUserPresence
        )
        let signedMessage = authenticatorData + request.clientDataHash
        var responses: [Data] = []
        responses.reserveCapacity(matches.count)
        for (index, record) in matches.enumerated() {
            let signature = try keys.sign(
                tag: record.keyTag,
                message: signedMessage,
                context: context
            )
            responses.append(CratePasskeyProtocol.assertionResponse(
                record: record,
                authenticatorData: authenticatorData,
                signature: signature,
                includeUser: request.allowedCredentialIDs == nil,
                numberOfCredentials: index == 0 ? matches.count : nil
            ))
        }

        let first = responses.removeFirst()
        if !responses.isEmpty {
            pendingAssertions = PendingAssertions(
                responses: responses,
                expiresAt: Date.now.addingTimeInterval(30)
            )
        }
        return first
    }

    private func nextAssertion() -> Data {
        guard var pending = pendingAssertions,
              pending.expiresAt > .now,
              !pending.responses.isEmpty else {
            pendingAssertions = nil
            return CratePasskeyProtocol.response(status: .notAllowed)
        }
        let response = pending.responses.removeFirst()
        pendingAssertions = pending.responses.isEmpty ? nil : pending
        return response
    }

    private func uniqueRandomCredentialID(
        existing records: [CratePasskeyCredentialRecord]
    ) throws -> Data {
        let existing = Set(records.map(\.credentialID))
        for _ in 0..<8 {
            var bytes = Data(count: CratePasskeyProtocol.credentialIDBytes)
            let status = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(
                    kSecRandomDefault,
                    buffer.count,
                    buffer.baseAddress!
                )
            }
            guard status == errSecSuccess else {
                throw SecurityKeyBackendError.unavailable(
                    "The system random-number generator failed (\(status))."
                )
            }
            if !existing.contains(bytes) { return bytes }
        }
        throw SecurityKeyBackendError.unavailable(
            "Crate could not generate a unique passkey identifier."
        )
    }
}

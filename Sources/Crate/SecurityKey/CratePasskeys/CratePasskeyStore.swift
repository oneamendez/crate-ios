// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Security

enum CratePasskeyStoreError: LocalizedError {
    case keychain(OSStatus)
    case corrupt
    case tooManyCredentials

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            (SecCopyErrorMessageString(status, nil) as String?)
                ?? "The passkey Keychain operation failed (\(status))."
        case .corrupt:
            "Crate's passkey index is damaged. Existing private keys were not changed."
        case .tooManyCredentials:
            "Crate Passkeys has reached its 256-credential device limit."
        }
    }
}

/// Stores only credential metadata. Each private key is a separate permanent
/// Secure Enclave key. This metadata is device-only, non-synchronizing and
/// available solely while the phone is unlocked.
final class CratePasskeyStore {
    private struct Envelope: Codable {
        let version: Int
        let records: [CratePasskeyCredentialRecord]
    }

    private let service: String
    private let account = "credential-index-v1"

    init(service: String = (Bundle.main.bundleIdentifier ?? "crate") + ".passkeys") {
        self.service = service
    }

    func load() throws -> [CratePasskeyCredentialRecord] {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CratePasskeyStoreError.keychain(status)
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw CratePasskeyStoreError.corrupt
        }
        guard envelope.version == 1,
              envelope.records.count <= CratePasskeyProtocol.maximumCredentialCount else {
            throw CratePasskeyStoreError.corrupt
        }

        var credentialIDs = Set<Data>()
        var keyTags = Set<Data>()
        for record in envelope.records {
            guard record.credentialID.count == CratePasskeyProtocol.credentialIDBytes,
                  !record.keyTag.isEmpty,
                  record.keyTag.count <= 256,
                  CratePasskeyProtocol.validRelyingPartyID(record.relyingPartyID),
                  (1...64).contains(record.userID.count),
                  credentialIDs.insert(record.credentialID).inserted,
                  keyTags.insert(record.keyTag).inserted else {
                throw CratePasskeyStoreError.corrupt
            }
        }
        return envelope.records
    }

    func save(_ records: [CratePasskeyCredentialRecord]) throws {
        guard records.count <= CratePasskeyProtocol.maximumCredentialCount else {
            throw CratePasskeyStoreError.tooManyCredentials
        }

        if records.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CratePasskeyStoreError.keychain(status)
            }
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, records: records))
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CratePasskeyStoreError.keychain(updateStatus)
        }

        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CratePasskeyStoreError.keychain(addStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

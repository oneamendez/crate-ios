// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import LocalAuthentication
import Security

@MainActor
final class CratePasskeyKeyProvider {
    struct PublicCoordinates {
        let x: Data
        let y: Data
    }

    private(set) var activeContext: LAContext?

    var authenticationDescription: String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return switch context.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "device authentication"
        }
    }

    func checkAvailability() throws {
        #if targetEnvironment(simulator)
        throw SecurityKeyBackendError.unavailable(
            "Secure Enclave passkeys require a physical iPhone or iPad."
        )
        #else
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw SecurityKeyBackendError.unavailable(
                error?.localizedDescription
                    ?? "Turn on a device passcode and Face ID or Touch ID to use Crate Passkeys."
            )
        }
        #endif
    }

    func authenticate(reason: String) async throws -> LAContext {
        try checkAvailability()
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        activeContext?.invalidate()
        activeContext = context

        do {
            let allowed = try await withTaskCancellationHandler {
                try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
            } onCancel: {
                context.invalidate()
            }
            guard allowed else { throw SecurityKeyBackendError.denied }
            guard !Task.isCancelled else { throw SecurityKeyBackendError.cancelled }
            if activeContext === context { activeContext = nil }
            return context
        } catch {
            if activeContext === context { activeContext = nil }
            throw Self.mapAuthenticationError(error)
        }
    }

    func createKey(tag: Data, context: LAContext) throws -> PublicCoordinates {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &accessError
        ) else {
            throw SecurityKeyBackendError.unavailable(
                (accessError?.takeRetainedValue() as Error?)?.localizedDescription
                    ?? "The Secure Enclave access policy could not be created."
            )
        }

        var creationError: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseAuthenticationContext as String: context,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        guard let privateKey = SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &creationError
        ) else {
            throw SecurityKeyBackendError.unavailable(
                (creationError?.takeRetainedValue() as Error?)?.localizedDescription
                    ?? "The Secure Enclave could not create a passkey."
            )
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            deleteKey(tag: tag)
            throw SecurityKeyBackendError.invalidResponse
        }

        var exportError: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(
            publicKey,
            &exportError
        ) as Data?,
              representation.count == 65,
              representation.first == 0x04 else {
            deleteKey(tag: tag)
            throw SecurityKeyBackendError.unavailable(
                (exportError?.takeRetainedValue() as Error?)?.localizedDescription
                    ?? "The Secure Enclave returned an invalid public key."
            )
        }
        return PublicCoordinates(
            x: representation.subdata(in: 1..<33),
            y: representation.subdata(in: 33..<65)
        )
    }

    func sign(tag: Data, message: Data, context: LAContext) throws -> Data {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag as String: tag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let item else {
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw SecurityKeyBackendError.cancelled
            }
            if status == errSecItemNotFound { throw SecurityKeyBackendError.disconnected }
            throw SecurityKeyBackendError.unavailable(
                (SecCopyErrorMessageString(status, nil) as String?)
                    ?? "The Secure Enclave passkey could not be opened."
            )
        }
        guard CFGetTypeID(item) == SecKeyGetTypeID() else {
            throw SecurityKeyBackendError.invalidResponse
        }
        let privateKey = unsafeBitCast(item, to: SecKey.self)
        guard SecKeyIsAlgorithmSupported(
            privateKey,
            .sign,
            .ecdsaSignatureMessageX962SHA256
        ) else {
            throw SecurityKeyBackendError.unsupported("This device cannot sign ES256 passkeys.")
        }

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &signingError
        ) as Data? else {
            let error = signingError?.takeRetainedValue() as Error?
            if let laError = error as? LAError {
                throw Self.mapAuthenticationError(laError)
            }
            throw SecurityKeyBackendError.unavailable(
                error?.localizedDescription ?? "The Secure Enclave could not sign the request."
            )
        }
        return signature
    }

    func deleteKey(tag: Data) {
        let status = SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag as String: tag,
        ] as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLog.write("crate passkeys: could not remove an orphaned Secure Enclave key (\(status))")
        }
    }

    func cancel() {
        activeContext?.invalidate()
        activeContext = nil
    }

    private static func mapAuthenticationError(_ error: Error) -> Error {
        guard let error = error as? LAError else {
            if error is CancellationError { return SecurityKeyBackendError.cancelled }
            return error
        }
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:
            return SecurityKeyBackendError.cancelled
        case .authenticationFailed, .userFallback:
            return SecurityKeyBackendError.denied
        case .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled,
             .passcodeNotSet:
            return SecurityKeyBackendError.unavailable(error.localizedDescription)
        default:
            return SecurityKeyBackendError.denied
        }
    }
}

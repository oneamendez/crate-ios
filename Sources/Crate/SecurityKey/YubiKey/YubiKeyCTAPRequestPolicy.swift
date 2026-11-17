// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The deliberately narrow CTAP surface Crate will forward to a USB-C
/// YubiKey. The guest never receives a generic APDU or management channel.
enum YubiKeyCTAPRequestPolicy {
    static let hardMaximumRequestBytes = 16 * 1024

    enum Decision: Equatable, Sendable {
        case getInfo
        case getAssertion(relyingPartyID: String, usesPINUVAuth: Bool)
        case getNextAssertion
        case selection
        case clientPIN(ClientPINOperation)
    }

    enum ClientPINOperation: Equatable, Sendable {
        case getRetries
        case getKeyAgreement
        case getAssertionToken(relyingPartyID: String)
    }

    enum ValidationError: Error, Equatable {
        case empty
        case tooLarge
        case deniedCommand
        case malformed
    }

    static func validate(_ request: Data, maximumBytes: Int = hardMaximumRequestBytes) throws -> Decision {
        guard let command = request.first else { throw ValidationError.empty }
        guard request.count <= min(maximumBytes, hardMaximumRequestBytes) else {
            throw ValidationError.tooLarge
        }

        let payload = Data(request.dropFirst())
        switch command {
        case 0x02: // authenticatorGetAssertion
            return try validateGetAssertion(payload)
        case 0x04: // authenticatorGetInfo
            guard payload.isEmpty else { throw ValidationError.malformed }
            return .getInfo
        case 0x06: // authenticatorClientPIN
            return .clientPIN(try validateClientPIN(payload))
        case 0x08: // authenticatorGetNextAssertion
            guard payload.isEmpty else { throw ValidationError.malformed }
            return .getNextAssertion
        case 0x0b: // authenticatorSelection
            guard payload.isEmpty else { throw ValidationError.malformed }
            return .selection
        default:
            // This intentionally includes makeCredential, reset, credential
            // management, bio enrollment, large blobs, configuration, vendor
            // commands, and future commands until they receive a review.
            throw ValidationError.deniedCommand
        }
    }

    /// The only RP ID safe to put in host UI. This deliberately returns nil
    /// unless the entire assertion request passes the same strict policy that
    /// gates the physical key.
    static func displayableRelyingPartyID(in request: Data) -> String? {
        guard case .getAssertion(let relyingPartyID, _) = try? validate(request) else {
            return nil
        }
        return relyingPartyID
    }

    private static func validateGetAssertion(_ payload: Data) throws -> Decision {
        let map = try unsignedMap(CBOR.decode(payload, maximumBytes: hardMaximumRequestBytes))
        guard !map.isEmpty, Set(map.keys).isSubset(of: Set(1...7)) else {
            throw ValidationError.malformed
        }

        guard let relyingPartyID = map[1]?.textValue,
              validRelyingPartyID(relyingPartyID),
              let clientDataHash = map[2]?.bytesValue,
              clientDataHash.count == 32 else {
            throw ValidationError.malformed
        }

        if let allowList = map[3] {
            try validateAllowList(allowList)
        }
        // v1 does not forward assertion extensions. Even nominally read-only
        // extensions can disclose per-credential material or add behavior that
        // has not been reviewed as part of this narrow bridge.
        guard map[4] == nil else { throw ValidationError.deniedCommand }
        if let options = map[5] {
            try validateOptions(options)
        }

        let pinUVAuthParam = map[6]?.bytesValue
        let pinUVAuthProtocol = map[7].flatMap(unsignedValue)
        guard (map[6] == nil) == (map[7] == nil) else {
            throw ValidationError.malformed
        }
        if let pinUVAuthParam, let pinUVAuthProtocol {
            switch pinUVAuthProtocol {
            case 1 where pinUVAuthParam.count == 16:
                break
            case 2 where pinUVAuthParam.count == 32:
                break
            default:
                throw ValidationError.malformed
            }
        } else if map[6] != nil || map[7] != nil {
            throw ValidationError.malformed
        }

        return .getAssertion(
            relyingPartyID: relyingPartyID,
            usesPINUVAuth: pinUVAuthParam != nil
        )
    }

    private static func validateAllowList(_ value: CBOR) throws {
        guard let descriptors = value.arrayValue, descriptors.count <= 64 else {
            throw ValidationError.malformed
        }
        for descriptor in descriptors {
            let fields = try textMap(descriptor)
            guard !fields.isEmpty,
                  Set(fields.keys).isSubset(of: ["id", "type", "transports"]),
                  fields["type"]?.textValue == "public-key",
                  let identifier = fields["id"]?.bytesValue,
                  (1...1024).contains(identifier.count) else {
                throw ValidationError.malformed
            }
            if let transports = fields["transports"] {
                guard let items = transports.arrayValue, items.count <= 8,
                      items.allSatisfy({ item in
                          guard let transport = item.textValue else { return false }
                          return !transport.isEmpty && transport.utf8.count <= 32
                      }) else {
                    throw ValidationError.malformed
                }
            }
        }
    }

    private static func validateOptions(_ value: CBOR) throws {
        let options = try textMap(value)
        guard Set(options.keys).isSubset(of: ["up", "uv"]),
              options.values.allSatisfy({ $0.booleanValue != nil }) else {
            throw ValidationError.malformed
        }
    }

    private static func validateClientPIN(_ payload: Data) throws -> ClientPINOperation {
        let map = try unsignedMap(CBOR.decode(payload, maximumBytes: hardMaximumRequestBytes))
        guard let version = map[1].flatMap(unsignedValue),
              version == 1 || version == 2,
              let subcommand = map[2].flatMap(unsignedValue) else {
            throw ValidationError.malformed
        }

        switch subcommand {
        case 0x01: // getPINRetries: read-only
            guard Set(map.keys) == [1, 2] else { throw ValidationError.malformed }
            return .getRetries
        case 0x02: // getKeyAgreement: read-only prerequisite
            guard Set(map.keys) == [1, 2] else { throw ValidationError.malformed }
            return .getKeyAgreement
        case 0x09: // getPinUvAuthTokenUsingPinWithPermissions
            guard Set(map.keys) == [1, 2, 3, 6, 9, 10],
                  let keyAgreement = map[3],
                  validP256KeyAgreement(keyAgreement),
                  let encryptedPINHash = map[6]?.bytesValue,
                  encryptedPINHash.count == (version == 1 ? 16 : 32),
                  map[9].flatMap(unsignedValue) == 0x02,
                  let relyingPartyID = map[10]?.textValue,
                  validRelyingPartyID(relyingPartyID) else {
                throw ValidationError.malformed
            }
            return .getAssertionToken(relyingPartyID: relyingPartyID)
        default:
            // setPIN/changePIN, legacy unscoped tokens, UV/biometric flows,
            // and all future subcommands are outside the assertion-only v1.
            throw ValidationError.deniedCommand
        }
    }

    private static func validP256KeyAgreement(_ keyAgreement: CBOR) -> Bool {
        guard let pairs = keyAgreement.mapValue, pairs.count == 5 else { return false }

        func field(for key: CBOR) -> CBOR? {
            pairs.first(where: { $0.key == key })?.value
        }

        guard field(for: .unsigned(1)).flatMap(unsignedValue) == 2, // EC2
              field(for: .unsigned(3)) == .negative(-25),           // ECDH-ES + HKDF-256
              field(for: .negative(-1)).flatMap(unsignedValue) == 1, // P-256
              let x = field(for: .negative(-2))?.bytesValue,
              let y = field(for: .negative(-3))?.bytesValue else {
            return false
        }
        return x.count == 32 && y.count == 32
    }

    private static func validRelyingPartyID(_ value: String) -> Bool {
        // WebAuthn RP IDs use only the domain form of a host: never a scheme,
        // port, path, IP literal, or opaque/Unicode host. Accept canonical,
        // lower-case ASCII LDH labels so this boundary cannot introduce bidi,
        // control, whitespace, or look-alike text into host-side UI/logging.
        // `localhost` is the one explicitly recognized single-label WebAuthn
        // development host. IP addresses are explicitly not RP IDs.
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 253,
              bytes.allSatisfy({ byte in
                  (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || byte == UInt8(ascii: "-")
                      || byte == UInt8(ascii: ".")
              }) else {
            return false
        }

        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1 || value == "localhost" else { return false }
        for label in labels {
            guard (1...63).contains(label.utf8.count),
                  let first = label.utf8.first,
                  let last = label.utf8.last,
                  isASCIILetterOrDigit(first),
                  isASCIILetterOrDigit(last) else {
                return false
            }
        }

        // A decimal final label catches IPv4 and non-domain numeric host forms.
        guard labels.last?.contains(where: { $0.isLetter }) == true else { return false }
        return true
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func unsignedMap(_ value: CBOR) throws -> [UInt64: CBOR] {
        guard let pairs = value.mapValue else { throw ValidationError.malformed }
        var result: [UInt64: CBOR] = [:]
        result.reserveCapacity(pairs.count)
        for pair in pairs {
            guard case .unsigned(let key) = pair.key else { throw ValidationError.malformed }
            result[key] = pair.value
        }
        return result
    }

    private static func textMap(_ value: CBOR) throws -> [String: CBOR] {
        guard let pairs = value.mapValue else { throw ValidationError.malformed }
        var result: [String: CBOR] = [:]
        result.reserveCapacity(pairs.count)
        for pair in pairs {
            guard case .text(let key) = pair.key else { throw ValidationError.malformed }
            result[key] = pair.value
        }
        return result
    }

    private static func unsignedValue(_ value: CBOR) -> UInt64? {
        guard case .unsigned(let number) = value else { return nil }
        return number
    }
}

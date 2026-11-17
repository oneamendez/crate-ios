// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation

struct CratePasskeyCredentialRecord: Codable, Equatable, Sendable {
    let credentialID: Data
    let keyTag: Data
    let relyingPartyID: String
    let userID: Data
    let userName: String?
    let userDisplayName: String?
    let discoverable: Bool
    let createdAt: Date
}

struct CratePasskeySummary: Equatable, Identifiable, Sendable {
    let id: String
    let relyingPartyID: String
    let userName: String?
    let createdAt: Date

    init(_ record: CratePasskeyCredentialRecord) {
        id = record.credentialID.base64EncodedString()
        relyingPartyID = record.relyingPartyID
        userName = record.userName ?? record.userDisplayName
        createdAt = record.createdAt
    }
}

/// The CTAP2.0 subset implemented by the phone-owned authenticator. Parsing
/// and byte assembly are kept independent from Keychain and LocalAuthentication
/// so protocol behavior can be tested on macOS without weakening device keys.
enum CratePasskeyProtocol {
    static let maximumRequestBytes = 4 * 1024
    static let maximumCredentialCount = 256
    static let credentialIDBytes = 32

    /// Stable model identifier for this development authenticator. It does not
    /// claim FIDO certification or identify an individual phone.
    static let aaguid = Data([
        0xcc, 0x84, 0x7a, 0x0d, 0x4d, 0xa9, 0x4c, 0x91,
        0xad, 0x2c, 0x99, 0xcd, 0xf5, 0xb2, 0xf4, 0x58,
    ])

    enum Status: UInt8, Error, Equatable {
        case invalidCommand = 0x01
        case invalidParameter = 0x02
        case invalidLength = 0x03
        case cborUnexpectedType = 0x11
        case invalidCBOR = 0x12
        case missingParameter = 0x14
        case limitExceeded = 0x15
        case unsupportedExtension = 0x16
        case credentialExcluded = 0x19
        case unsupportedAlgorithm = 0x26
        case operationDenied = 0x27
        case keyStoreFull = 0x28
        case unsupportedOption = 0x2b
        case invalidOption = 0x2c
        case keepaliveCancel = 0x2d
        case noCredentials = 0x2e
        case userActionTimeout = 0x2f
        case notAllowed = 0x30
        case other = 0x7f
    }

    struct MakeCredentialRequest: Equatable, Sendable {
        let clientDataHash: Data
        let relyingPartyID: String
        let relyingPartyName: String?
        let userID: Data
        let userName: String?
        let userDisplayName: String?
        let excludedCredentialIDs: [Data]
        let discoverable: Bool
    }

    struct GetAssertionRequest: Equatable, Sendable {
        let relyingPartyID: String
        let clientDataHash: Data
        let allowedCredentialIDs: [Data]?
        let requiresUserPresence: Bool
    }

    enum Command: Equatable, Sendable {
        case makeCredential(MakeCredentialRequest)
        case getAssertion(GetAssertionRequest)
        case getInfo
        case getNextAssertion
        case selection
    }

    static func decode(_ request: Data) throws -> Command {
        guard let command = request.first else { throw Status.invalidLength }
        guard request.count <= maximumRequestBytes else { throw Status.invalidLength }
        let payload = Data(request.dropFirst())

        switch command {
        case 0x01:
            return .makeCredential(try decodeMakeCredential(payload))
        case 0x02:
            return .getAssertion(try decodeGetAssertion(payload))
        case 0x04:
            guard payload.isEmpty else { throw Status.invalidLength }
            return .getInfo
        case 0x08:
            guard payload.isEmpty else { throw Status.invalidLength }
            return .getNextAssertion
        case 0x0b:
            guard payload.isEmpty else { throw Status.invalidLength }
            return .selection
        default:
            throw Status.invalidCommand
        }
    }

    static func displayableRelyingPartyID(in request: Data) -> String? {
        switch try? decode(request) {
        case .makeCredential(let request): request.relyingPartyID
        case .getAssertion(let request): request.relyingPartyID
        default: nil
        }
    }

    static func getInfoResponse() -> Data {
        success(.map([
            .init(key: .unsigned(1), value: .array([.text("FIDO_2_0")])),
            .init(key: .unsigned(3), value: .bytes(aaguid)),
            .init(key: .unsigned(4), value: .map([
                .init(key: .text("rk"), value: .boolean(true)),
                .init(key: .text("up"), value: .boolean(true)),
                .init(key: .text("uv"), value: .boolean(true)),
            ])),
            .init(key: .unsigned(5), value: .unsigned(UInt64(maximumRequestBytes))),
            .init(key: .unsigned(7), value: .unsigned(64)),
            .init(key: .unsigned(8), value: .unsigned(UInt64(credentialIDBytes))),
        ]))
    }

    static func makeCredentialResponse(relyingPartyID: String,
                                       credentialID: Data,
                                       publicKeyX: Data,
                                       publicKeyY: Data) throws -> Data {
        guard credentialID.count == credentialIDBytes,
              publicKeyX.count == 32,
              publicKeyY.count == 32 else {
            throw Status.other
        }

        let credentialPublicKey = CBOR.map([
            .init(key: .unsigned(1), value: .unsigned(2)),       // kty: EC2
            .init(key: .unsigned(3), value: .negative(-7)),     // alg: ES256
            .init(key: .negative(-1), value: .unsigned(1)),     // crv: P-256
            .init(key: .negative(-2), value: .bytes(publicKeyX)),
            .init(key: .negative(-3), value: .bytes(publicKeyY)),
        ]).encoded

        var authenticatorData = Data(SHA256.hash(data: Data(relyingPartyID.utf8)))
        authenticatorData.append(0x45) // UP | UV | AT
        authenticatorData.append(contentsOf: [0, 0, 0, 0]) // no signature counter
        authenticatorData.append(aaguid)
        authenticatorData.append(UInt8(credentialID.count >> 8))
        authenticatorData.append(UInt8(credentialID.count & 0xff))
        authenticatorData.append(credentialID)
        authenticatorData.append(credentialPublicKey)

        return success(.map([
            .init(key: .unsigned(1), value: .text("none")),
            .init(key: .unsigned(2), value: .bytes(authenticatorData)),
            .init(key: .unsigned(3), value: .map([])),
        ]))
    }

    static func assertionAuthenticatorData(relyingPartyID: String,
                                           userPresent: Bool = true) -> Data {
        var result = Data(SHA256.hash(data: Data(relyingPartyID.utf8)))
        // Device authentication supplies UV. A pre-flight request may omit UP.
        result.append(userPresent ? 0x05 : 0x04)
        result.append(contentsOf: [0, 0, 0, 0])
        return result
    }

    static func assertionResponse(record: CratePasskeyCredentialRecord,
                                  authenticatorData: Data,
                                  signature: Data,
                                  includeUser: Bool,
                                  numberOfCredentials: Int? = nil) -> Data {
        var pairs = [
            CBOR.Pair(key: .unsigned(1), value: .map([
                .init(key: .text("id"), value: .bytes(record.credentialID)),
                .init(key: .text("type"), value: .text("public-key")),
            ])),
            .init(key: .unsigned(2), value: .bytes(authenticatorData)),
            .init(key: .unsigned(3), value: .bytes(signature)),
        ]

        if includeUser {
            var user = [CBOR.Pair(key: .text("id"), value: .bytes(record.userID))]
            if let name = record.userName {
                user.append(.init(key: .text("name"), value: .text(name)))
            }
            if let displayName = record.userDisplayName {
                user.append(.init(key: .text("displayName"), value: .text(displayName)))
            }
            pairs.append(.init(key: .unsigned(4), value: .map(user)))
        }
        if let numberOfCredentials, numberOfCredentials > 1 {
            pairs.append(.init(key: .unsigned(5), value: .unsigned(UInt64(numberOfCredentials))))
        }
        return success(.map(pairs))
    }

    static func response(status: Status) -> Data {
        Data([status.rawValue])
    }

    static func validRelyingPartyID(_ value: String) -> Bool {
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
        guard value == "localhost"
                || labels.last?.contains(where: { $0.isLetter }) == true else {
            return false
        }
        return true
    }

    private static func decodeMakeCredential(_ payload: Data) throws -> MakeCredentialRequest {
        let map = try decodeUnsignedMap(payload)
        guard Set(map.keys).isSubset(of: Set(1...11)) else { throw Status.invalidCBOR }
        guard let clientDataHash = try requiredBytes(map[1]), clientDataHash.count == 32,
              let rpValue = map[2], let userValue = map[3],
              let parametersValue = map[4] else {
            throw Status.missingParameter
        }

        let rp = try textMap(rpValue)
        guard Set(rp.keys).isSubset(of: ["id", "name", "icon"]),
              let relyingPartyID = try requiredText(rp["id"]),
              validRelyingPartyID(relyingPartyID) else {
            throw Status.invalidParameter
        }
        let relyingPartyName = try optionalBoundedText(rp["name"], maximumUTF8Bytes: 256)

        let user = try textMap(userValue)
        guard Set(user.keys).isSubset(of: ["id", "name", "displayName", "icon"]),
              let userID = try requiredBytes(user["id"]),
              (1...64).contains(userID.count) else {
            throw Status.invalidParameter
        }
        let userName = try optionalBoundedText(user["name"], maximumUTF8Bytes: 256)
        let userDisplayName = try optionalBoundedText(user["displayName"], maximumUTF8Bytes: 256)

        guard let parameters = parametersValue.arrayValue, !parameters.isEmpty,
              parameters.count <= 64 else {
            throw Status.cborUnexpectedType
        }
        var supportsES256 = false
        for parameter in parameters {
            let fields = try textMap(parameter)
            guard Set(fields.keys).isSubset(of: ["type", "alg"]),
                  try requiredText(fields["type"]) == "public-key",
                  let algorithm = try integer(fields["alg"]) else {
                throw Status.invalidCBOR
            }
            if algorithm == -7 { supportsES256 = true }
        }
        guard supportsES256 else { throw Status.unsupportedAlgorithm }

        let excluded = try map[5].map(credentialIDs) ?? []
        try rejectExtensions(map[6])
        let options = try map[7].map(textMap) ?? [:]
        let discoverable = try optionalBoolean(options["rk"]) ?? false
        if let up = try optionalBoolean(options["up"]), !up { throw Status.invalidOption }
        _ = try optionalBoolean(options["uv"])

        // This authenticator uses built-in device authentication and does not
        // advertise a PIN/UV protocol. Clients must not send PIN parameters.
        guard map[8] == nil, map[9] == nil else { throw Status.unsupportedOption }
        guard map[10] == nil else { throw Status.invalidParameter }

        return MakeCredentialRequest(
            clientDataHash: clientDataHash,
            relyingPartyID: relyingPartyID,
            relyingPartyName: relyingPartyName,
            userID: userID,
            userName: userName,
            userDisplayName: userDisplayName,
            excludedCredentialIDs: excluded,
            discoverable: discoverable
        )
    }

    private static func decodeGetAssertion(_ payload: Data) throws -> GetAssertionRequest {
        let map = try decodeUnsignedMap(payload)
        guard Set(map.keys).isSubset(of: Set(1...7)),
              let relyingPartyID = try requiredText(map[1]),
              validRelyingPartyID(relyingPartyID),
              let clientDataHash = try requiredBytes(map[2]),
              clientDataHash.count == 32 else {
            throw Status.missingParameter
        }

        let allowList = try map[3].map(credentialIDs)
        if let allowList, allowList.isEmpty { throw Status.invalidParameter }
        try rejectExtensions(map[4])
        let options = try map[5].map(textMap) ?? [:]
        let userPresence = try optionalBoolean(options["up"]) ?? true
        _ = try optionalBoolean(options["uv"])
        guard map[6] == nil, map[7] == nil else { throw Status.unsupportedOption }

        return GetAssertionRequest(
            relyingPartyID: relyingPartyID,
            clientDataHash: clientDataHash,
            allowedCredentialIDs: allowList,
            requiresUserPresence: userPresence
        )
    }

    private static func credentialIDs(_ value: CBOR) throws -> [Data] {
        guard let descriptors = value.arrayValue, descriptors.count <= 64 else {
            throw Status.limitExceeded
        }
        return try descriptors.map { descriptor in
            let fields = try textMap(descriptor)
            guard Set(fields.keys).isSubset(of: ["id", "type", "transports"]),
                  try requiredText(fields["type"]) == "public-key",
                  let identifier = try requiredBytes(fields["id"]),
                  (1...1024).contains(identifier.count) else {
                throw Status.invalidParameter
            }
            if let transports = fields["transports"] {
                guard let values = transports.arrayValue, values.count <= 8 else {
                    throw Status.cborUnexpectedType
                }
                for transport in values {
                    guard let name = transport.textValue,
                          !name.isEmpty, name.utf8.count <= 32 else {
                        throw Status.cborUnexpectedType
                    }
                }
            }
            return identifier
        }
    }

    private static func rejectExtensions(_ value: CBOR?) throws {
        guard let value else { return }
        guard let pairs = value.mapValue else { throw Status.cborUnexpectedType }
        if !pairs.isEmpty { throw Status.unsupportedExtension }
    }

    private static func decodeUnsignedMap(_ payload: Data) throws -> [UInt64: CBOR] {
        let decoded: CBOR
        do {
            decoded = try CBOR.decode(payload, maximumBytes: maximumRequestBytes)
        } catch {
            throw Status.invalidCBOR
        }
        guard let pairs = decoded.mapValue else { throw Status.cborUnexpectedType }
        var result: [UInt64: CBOR] = [:]
        for pair in pairs {
            guard case .unsigned(let key) = pair.key else { throw Status.cborUnexpectedType }
            result[key] = pair.value
        }
        return result
    }

    private static func textMap(_ value: CBOR) throws -> [String: CBOR] {
        guard let pairs = value.mapValue else { throw Status.cborUnexpectedType }
        var result: [String: CBOR] = [:]
        for pair in pairs {
            guard case .text(let key) = pair.key else { throw Status.cborUnexpectedType }
            result[key] = pair.value
        }
        return result
    }

    private static func requiredBytes(_ value: CBOR?) throws -> Data? {
        guard let value else { return nil }
        guard let bytes = value.bytesValue else { throw Status.cborUnexpectedType }
        return bytes
    }

    private static func requiredText(_ value: CBOR?) throws -> String? {
        guard let value else { return nil }
        guard let text = value.textValue else { throw Status.cborUnexpectedType }
        return text
    }

    private static func optionalBoundedText(_ value: CBOR?,
                                            maximumUTF8Bytes: Int) throws -> String? {
        guard let text = try requiredText(value) else { return nil }
        guard text.utf8.count <= maximumUTF8Bytes else { throw Status.limitExceeded }
        return text
    }

    private static func optionalBoolean(_ value: CBOR?) throws -> Bool? {
        guard let value else { return nil }
        guard let boolean = value.booleanValue else { throw Status.cborUnexpectedType }
        return boolean
    }

    private static func integer(_ value: CBOR?) throws -> Int64? {
        guard let value else { return nil }
        switch value {
        case .unsigned(let number):
            guard number <= UInt64(Int64.max) else { throw Status.invalidParameter }
            return Int64(number)
        case .negative(let number):
            return number
        default:
            throw Status.cborUnexpectedType
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func success(_ value: CBOR) -> Data {
        Data([0x00]) + value.encoded
    }
}

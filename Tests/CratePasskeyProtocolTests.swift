import CryptoKit
import Foundation

@main
struct CratePasskeyProtocolTests {
    static func main() throws {
        try makeCredentialRoundTrip()
        try getInfoShape()
        try assertionShape()
        try malformedRequestsFailClosed()
        print("CratePasskeyProtocolTests: passed")
    }

    private static func makeCredentialRoundTrip() throws {
        let clientHash = Data(repeating: 0x11, count: 32)
        let userID = Data([1, 2, 3, 4])
        let payload = CBOR.map([
            .init(key: .unsigned(1), value: .bytes(clientHash)),
            .init(key: .unsigned(2), value: .map([
                .init(key: .text("id"), value: .text("login.example")),
                .init(key: .text("name"), value: .text("Example")),
            ])),
            .init(key: .unsigned(3), value: .map([
                .init(key: .text("id"), value: .bytes(userID)),
                .init(key: .text("name"), value: .text("user@example.com")),
                .init(key: .text("displayName"), value: .text("Example User")),
            ])),
            .init(key: .unsigned(4), value: .array([
                .map([
                    .init(key: .text("alg"), value: .negative(-7)),
                    .init(key: .text("type"), value: .text("public-key")),
                ]),
            ])),
            .init(key: .unsigned(7), value: .map([
                .init(key: .text("rk"), value: .boolean(true)),
                .init(key: .text("uv"), value: .boolean(true)),
            ])),
        ])
        let command = try CratePasskeyProtocol.decode(Data([0x01]) + payload.encoded)
        guard case .makeCredential(let request) = command else {
            preconditionFailure("decoded the wrong command")
        }
        precondition(request.clientDataHash == clientHash)
        precondition(request.relyingPartyID == "login.example")
        precondition(request.userID == userID)
        precondition(request.discoverable)

        let credentialID = Data(repeating: 0x22, count: 32)
        let response = try CratePasskeyProtocol.makeCredentialResponse(
            relyingPartyID: request.relyingPartyID,
            credentialID: credentialID,
            publicKeyX: Data(repeating: 0x33, count: 32),
            publicKeyY: Data(repeating: 0x44, count: 32)
        )
        precondition(response.first == 0)
        let map = try CBOR.decode(Data(response.dropFirst()))
        precondition(map.value(forUnsigned: 1)?.textValue == "none")
        precondition(map.value(forUnsigned: 3) == .map([]))
        let authData = map.value(forUnsigned: 2)!.bytesValue!
        precondition(authData.prefix(32) == Data(SHA256.hash(data: Data("login.example".utf8))))
        precondition(authData[32] == 0x45)
        precondition(authData.subdata(in: 37..<53) == CratePasskeyProtocol.aaguid)
        precondition(authData[53] == 0 && authData[54] == 32)
        precondition(authData.subdata(in: 55..<87) == credentialID)
        let publicKey = try CBOR.decode(Data(authData.dropFirst(87)))
        precondition(publicKey.value(forUnsigned: 1) == .unsigned(2))
        precondition(publicKey.value(forUnsigned: 3) == .negative(-7))
    }

    private static func getInfoShape() throws {
        let response = CratePasskeyProtocol.getInfoResponse()
        precondition(response.first == 0)
        let info = try CBOR.decode(Data(response.dropFirst()))
        precondition(info.value(forUnsigned: 1) == .array([.text("FIDO_2_0")]))
        precondition(info.value(forUnsigned: 3)?.bytesValue?.count == 16)
        let options = info.value(forUnsigned: 4)!
        precondition(options.value(forText: "rk")?.booleanValue == true)
        precondition(options.value(forText: "uv")?.booleanValue == true)
    }

    private static func assertionShape() throws {
        let record = CratePasskeyCredentialRecord(
            credentialID: Data(repeating: 0x55, count: 32),
            keyTag: Data("key".utf8),
            relyingPartyID: "login.example",
            userID: Data([9, 8, 7]),
            userName: "user@example.com",
            userDisplayName: "Example User",
            discoverable: true,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let authData = CratePasskeyProtocol.assertionAuthenticatorData(
            relyingPartyID: record.relyingPartyID
        )
        precondition(authData.count == 37)
        precondition(authData[32] == 0x05)
        let response = CratePasskeyProtocol.assertionResponse(
            record: record,
            authenticatorData: authData,
            signature: Data([0x30, 0x01]),
            includeUser: true,
            numberOfCredentials: 2
        )
        let decoded = try CBOR.decode(Data(response.dropFirst()))
        precondition(decoded.value(forUnsigned: 2)?.bytesValue == authData)
        precondition(decoded.value(forUnsigned: 3)?.bytesValue == Data([0x30, 0x01]))
        precondition(decoded.value(forUnsigned: 4)?.value(forText: "id")?.bytesValue == record.userID)
        precondition(decoded.value(forUnsigned: 5) == .unsigned(2))
    }

    private static func malformedRequestsFailClosed() throws {
        precondition(CratePasskeyProtocol.validRelyingPartyID("login.example"))
        precondition(CratePasskeyProtocol.validRelyingPartyID("localhost"))
        for invalid in ["Example.com", "https://example.com", "example", "127.0.0.1"] {
            precondition(!CratePasskeyProtocol.validRelyingPartyID(invalid))
        }

        let unsupported = CBOR.map([
            .init(key: .unsigned(1), value: .bytes(Data(repeating: 1, count: 32))),
            .init(key: .unsigned(2), value: .map([
                .init(key: .text("id"), value: .text("login.example")),
            ])),
            .init(key: .unsigned(3), value: .map([
                .init(key: .text("id"), value: .bytes(Data([1]))),
            ])),
            .init(key: .unsigned(4), value: .array([
                .map([
                    .init(key: .text("alg"), value: .negative(-257)),
                    .init(key: .text("type"), value: .text("public-key")),
                ]),
            ])),
        ])
        expect(.unsupportedAlgorithm, decoding: Data([0x01]) + unsupported.encoded)

        var emptyUser = unsupported
        if case .map(var pairs) = emptyUser,
           let userIndex = pairs.firstIndex(where: { $0.key == .unsigned(3) }) {
            pairs[userIndex] = .init(key: .unsigned(3), value: .map([
                .init(key: .text("id"), value: .bytes(Data())),
            ]))
            if let parametersIndex = pairs.firstIndex(where: { $0.key == .unsigned(4) }) {
                pairs[parametersIndex] = .init(key: .unsigned(4), value: .array([
                    .map([
                        .init(key: .text("alg"), value: .negative(-7)),
                        .init(key: .text("type"), value: .text("public-key")),
                    ]),
                ]))
            }
            emptyUser = .map(pairs)
        }
        expect(.invalidParameter, decoding: Data([0x01]) + emptyUser.encoded)
        expect(.invalidLength, decoding: Data([0x04, 0xa0]))
        expect(.invalidCommand, decoding: Data([0x07]))
    }

    private static func expect(_ status: CratePasskeyProtocol.Status, decoding data: Data) {
        do {
            _ = try CratePasskeyProtocol.decode(data)
            preconditionFailure("accepted invalid CTAP request")
        } catch let actual as CratePasskeyProtocol.Status {
            precondition(actual == status, "expected \(status), got \(actual)")
        } catch {
            preconditionFailure("unexpected error: \(error)")
        }
    }
}

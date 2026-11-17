import Foundation

@main
struct YubiKeyCTAPRequestPolicyTests {
    static func main() throws {
        let getInfo = try YubiKeyCTAPRequestPolicy.validate(Data([0x04]))
        precondition(getInfo == .getInfo)
        let selection = try YubiKeyCTAPRequestPolicy.validate(Data([0x0b]))
        precondition(selection == .selection)

        let assertion = CBOR.map([
            .init(key: .unsigned(1), value: .text("login.example")),
            .init(key: .unsigned(2), value: .bytes(Data(repeating: 0x11, count: 32))),
        ])
        let assertionRequest = Data([0x02]) + assertion.encoded
        let assertionDecision = try YubiKeyCTAPRequestPolicy.validate(assertionRequest)
        precondition(
            assertionDecision == .getAssertion(relyingPartyID: "login.example", usesPINUVAuth: false)
        )

        let retries = CBOR.map([
            .init(key: .unsigned(1), value: .unsigned(2)),
            .init(key: .unsigned(2), value: .unsigned(1)),
        ])
        let retriesDecision = try YubiKeyCTAPRequestPolicy.validate(Data([0x06]) + retries.encoded)
        precondition(retriesDecision == .clientPIN(.getRetries))

        let keyAgreement = CBOR.map([
            .init(key: .unsigned(1), value: .unsigned(2)),
            .init(key: .unsigned(3), value: .negative(-25)),
            .init(key: .negative(-1), value: .unsigned(1)),
            .init(key: .negative(-2), value: .bytes(Data(repeating: 0x22, count: 32))),
            .init(key: .negative(-3), value: .bytes(Data(repeating: 0x33, count: 32))),
        ])
        let token = CBOR.map([
            .init(key: .unsigned(1), value: .unsigned(2)),
            .init(key: .unsigned(2), value: .unsigned(9)),
            .init(key: .unsigned(3), value: keyAgreement),
            // Protocol 2 prepends a random 16-byte IV to the encrypted 16-byte PIN hash.
            .init(key: .unsigned(6), value: .bytes(Data(repeating: 0x44, count: 32))),
            .init(key: .unsigned(9), value: .unsigned(2)),
            .init(key: .unsigned(10), value: .text("login.example")),
        ])
        let tokenDecision = try YubiKeyCTAPRequestPolicy.validate(Data([0x06]) + token.encoded)
        precondition(tokenDecision == .clientPIN(.getAssertionToken(relyingPartyID: "login.example")))

        var wrongProtocolTwoLength = token.mapValue!
        let pinHashIndex = wrongProtocolTwoLength.firstIndex { $0.key == .unsigned(6) }!
        wrongProtocolTwoLength[pinHashIndex] = .init(
            key: .unsigned(6), value: .bytes(Data(repeating: 0x44, count: 16))
        )
        expectDenied(Data([0x06]) + CBOR.map(wrongProtocolTwoLength).encoded)

        var protocolOneToken = wrongProtocolTwoLength
        let protocolIndex = protocolOneToken.firstIndex { $0.key == .unsigned(1) }!
        protocolOneToken[protocolIndex] = .init(key: .unsigned(1), value: .unsigned(1))
        let protocolOneDecision = try YubiKeyCTAPRequestPolicy.validate(
            Data([0x06]) + CBOR.map(protocolOneToken).encoded
        )
        precondition(
            protocolOneDecision == .clientPIN(.getAssertionToken(relyingPartyID: "login.example"))
        )

        expectDenied(Data([0x01])) // makeCredential
        expectDenied(Data([0x07])) // reset
        expectDenied(Data([0x0a])) // credential management
        expectDenied(Data([0x0d])) // authenticator config
        expectDenied(Data([0x04, 0xa0])) // GetInfo must not have a payload

        let malformedAssertion = CBOR.map([
            .init(key: .unsigned(1), value: .text("login.example")),
            .init(key: .unsigned(2), value: .bytes(Data(repeating: 0x11, count: 31))),
        ])
        expectDenied(Data([0x02]) + malformedAssertion.encoded)

        for invalidRelyingPartyID in [
            "Login.example", "logín.example", "https://login.example", "login.example/path",
            "login.example:443", "login.example.", ".login.example", "login..example",
            "-login.example", "login-.example", "127.0.0.1", "::1", "com",
        ] {
            let invalidRequest = makeAssertionRequest(relyingPartyID: invalidRelyingPartyID)
            expectDenied(invalidRequest)
            precondition(YubiKeyCTAPRequestPolicy.displayableRelyingPartyID(in: invalidRequest) == nil)
        }
        let localhost = try YubiKeyCTAPRequestPolicy.validate(
            makeAssertionRequest(relyingPartyID: "localhost")
        )
        precondition(localhost == .getAssertion(relyingPartyID: "localhost", usesPINUVAuth: false))
        precondition(
            YubiKeyCTAPRequestPolicy.displayableRelyingPartyID(
                in: makeAssertionRequest(relyingPartyID: "login.example")
            ) == "login.example"
        )

        let assertionWithExtension = CBOR.map([
            .init(key: .unsigned(1), value: .text("login.example")),
            .init(key: .unsigned(2), value: .bytes(Data(repeating: 0x11, count: 32))),
            .init(key: .unsigned(4), value: .map([])),
        ])
        expectDenied(Data([0x02]) + assertionWithExtension.encoded)

        var managementToken = token.mapValue!
        let permissionIndex = managementToken.firstIndex { $0.key == .unsigned(9) }!
        managementToken[permissionIndex] = .init(key: .unsigned(9), value: .unsigned(4))
        expectDenied(Data([0x06]) + CBOR.map(managementToken).encoded)

        let legacyToken = CBOR.map([
            .init(key: .unsigned(1), value: .unsigned(1)),
            .init(key: .unsigned(2), value: .unsigned(5)),
            .init(key: .unsigned(3), value: keyAgreement),
            .init(key: .unsigned(6), value: .bytes(Data(repeating: 0x55, count: 16))),
        ])
        expectDenied(Data([0x06]) + legacyToken.encoded)

        print("YubiKeyCTAPRequestPolicyTests: passed")
    }

    private static func expectDenied(_ request: Data) {
        do {
            _ = try YubiKeyCTAPRequestPolicy.validate(request)
            preconditionFailure("accepted a request outside the assertion-only policy")
        } catch {
            // Every validation failure is a denial at the backend boundary.
        }
    }

    private static func makeAssertionRequest(relyingPartyID: String) -> Data {
        let payload = CBOR.map([
            .init(key: .unsigned(1), value: .text(relyingPartyID)),
            .init(key: .unsigned(2), value: .bytes(Data(repeating: 0x11, count: 32))),
        ])
        return Data([0x02]) + payload.encoded
    }
}

import Foundation

@main
struct SecurityKeyCBORTests {
    static func main() throws {
        let request = Data([0xa2, 0x01, 0x61, 0x61, 0x02, 0x42, 0x01, 0x02])
        let decoded = try CBOR.decode(request)
        precondition(decoded.value(forUnsigned: 1)?.textValue == "a")
        precondition(decoded.value(forUnsigned: 2)?.bytesValue == Data([1, 2]))
        precondition(decoded.encoded == request)

        let deterministic = CBOR.map([
            .init(key: .text("z"), value: .unsigned(2)),
            .init(key: .unsigned(1), value: .unsigned(1)),
        ]).encoded
        precondition(deterministic == Data([0xa2, 0x01, 0x01, 0x61, 0x7a, 0x02]))

        expect(.duplicateKey, decoding: [0xa2, 0x01, 0x01, 0x01, 0x02])
        expect(.unsupported, decoding: [0x9f, 0x01, 0xff])
        expect(.nonCanonical, decoding: [0x18, 0x01])
        expect(.trailingData, decoding: [0x01, 0x02])
        expect(.invalidUTF8, decoding: [0x61, 0xff])
        expect(.truncated, decoding: [0x42, 0x01])
        print("SecurityKeyCBORTests: passed")
    }

    private static func expect(_ expected: CBORError, decoding bytes: [UInt8]) {
        do {
            _ = try CBOR.decode(Data(bytes))
            preconditionFailure("accepted invalid CBOR: \(bytes)")
        } catch let error as CBORError {
            precondition(error == expected, "expected \(expected), got \(error)")
        } catch {
            preconditionFailure("unexpected error: \(error)")
        }
    }
}

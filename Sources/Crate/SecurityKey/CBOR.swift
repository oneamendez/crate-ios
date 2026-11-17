// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The deliberately small CBOR subset CTAP2 uses. Indefinite lengths, tags,
/// floating point values and duplicate map keys are rejected.
indirect enum CBOR: Equatable, Sendable {
    struct Pair: Equatable, Sendable {
        let key: CBOR
        let value: CBOR
    }

    case unsigned(UInt64)
    case negative(Int64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([Pair])
    case boolean(Bool)
    case null

    static func decode(_ data: Data, maximumBytes: Int = 16 * 1024) throws -> CBOR {
        guard data.count <= maximumBytes else { throw CBORError.tooLarge }
        var parser = CBORParser(bytes: Array(data), maximumBytes: maximumBytes)
        let value = try parser.value(depth: 0)
        guard parser.isAtEnd else { throw CBORError.trailingData }
        return value
    }

    var encoded: Data {
        var bytes: [UInt8] = []
        encode(into: &bytes)
        return Data(bytes)
    }

    func value(forUnsigned key: UInt64) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == .unsigned(key) }?.value
    }

    func value(forText key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == .text(key) }?.value
    }

    var bytesValue: Data? {
        guard case .bytes(let value) = self else { return nil }
        return value
    }

    var textValue: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    var arrayValue: [CBOR]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var mapValue: [Pair]? {
        guard case .map(let value) = self else { return nil }
        return value
    }

    var booleanValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }

    private func encode(into bytes: inout [UInt8]) {
        switch self {
        case .unsigned(let value):
            Self.appendHead(major: 0, value: value, to: &bytes)
        case .negative(let value):
            precondition(value < 0)
            Self.appendHead(major: 1, value: UInt64(-(value + 1)), to: &bytes)
        case .bytes(let value):
            Self.appendHead(major: 2, value: UInt64(value.count), to: &bytes)
            bytes.append(contentsOf: value)
        case .text(let value):
            let utf8 = Array(value.utf8)
            Self.appendHead(major: 3, value: UInt64(utf8.count), to: &bytes)
            bytes.append(contentsOf: utf8)
        case .array(let values):
            Self.appendHead(major: 4, value: UInt64(values.count), to: &bytes)
            for value in values { value.encode(into: &bytes) }
        case .map(let pairs):
            let ordered = pairs.map { ($0.key.encoded, $0.value) }.sorted {
                $0.0.count == $1.0.count ? $0.0.lexicographicallyPrecedes($1.0) : $0.0.count < $1.0.count
            }
            Self.appendHead(major: 5, value: UInt64(ordered.count), to: &bytes)
            for (key, value) in ordered {
                bytes.append(contentsOf: key)
                value.encode(into: &bytes)
            }
        case .boolean(let value):
            bytes.append(value ? 0xf5 : 0xf4)
        case .null:
            bytes.append(0xf6)
        }
    }

    private static func appendHead(major: UInt8, value: UInt64, to bytes: inout [UInt8]) {
        let prefix = major << 5
        switch value {
        case 0..<24:
            bytes.append(prefix | UInt8(value))
        case 24...UInt64(UInt8.max):
            bytes.append(prefix | 24)
            bytes.append(UInt8(value))
        case 256...UInt64(UInt16.max):
            bytes.append(prefix | 25)
            bytes.append(contentsOf: withUnsafeBytes(of: UInt16(value).bigEndian, Array.init))
        case 65_536...UInt64(UInt32.max):
            bytes.append(prefix | 26)
            bytes.append(contentsOf: withUnsafeBytes(of: UInt32(value).bigEndian, Array.init))
        default:
            bytes.append(prefix | 27)
            bytes.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
        }
    }
}

enum CBORError: Error, Equatable {
    case truncated
    case tooLarge
    case tooDeep
    case tooManyItems
    case unsupported
    case nonCanonical
    case duplicateKey
    case invalidUTF8
    case integerOverflow
    case trailingData
}

private struct CBORParser {
    let bytes: [UInt8]
    let maximumBytes: Int
    private(set) var offset = 0

    var isAtEnd: Bool { offset == bytes.count }

    mutating func value(depth: Int) throws -> CBOR {
        guard depth <= 12 else { throw CBORError.tooDeep }
        let first = try takeByte()
        let major = first >> 5
        let additional = first & 0x1f

        switch major {
        case 0:
            return .unsigned(try length(additional))
        case 1:
            let encoded = try length(additional)
            guard encoded <= UInt64(Int64.max) else { throw CBORError.integerOverflow }
            return .negative(-1 - Int64(encoded))
        case 2:
            let count = try boundedCount(additional)
            return .bytes(Data(try take(count)))
        case 3:
            let count = try boundedCount(additional)
            let value = Data(try take(count))
            guard let text = String(data: value, encoding: .utf8) else { throw CBORError.invalidUTF8 }
            return .text(text)
        case 4:
            let count = try itemCount(additional)
            var values: [CBOR] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try value(depth: depth + 1)) }
            return .array(values)
        case 5:
            let count = try itemCount(additional)
            var pairs: [CBOR.Pair] = []
            var keys = Set<Data>()
            pairs.reserveCapacity(count)
            for _ in 0..<count {
                let key = try value(depth: depth + 1)
                guard keys.insert(key.encoded).inserted else { throw CBORError.duplicateKey }
                pairs.append(.init(key: key, value: try value(depth: depth + 1)))
            }
            return .map(pairs)
        case 7:
            switch additional {
            case 20: return .boolean(false)
            case 21: return .boolean(true)
            case 22: return .null
            default: throw CBORError.unsupported
            }
        default:
            throw CBORError.unsupported
        }
    }

    private mutating func boundedCount(_ additional: UInt8) throws -> Int {
        let count = try length(additional)
        guard count <= UInt64(maximumBytes), count <= UInt64(Int.max) else { throw CBORError.tooLarge }
        return Int(count)
    }

    private mutating func itemCount(_ additional: UInt8) throws -> Int {
        let count = try boundedCount(additional)
        guard count <= 256 else { throw CBORError.tooManyItems }
        return count
    }

    private mutating func length(_ additional: UInt8) throws -> UInt64 {
        switch additional {
        case 0..<24:
            return UInt64(additional)
        case 24:
            let value = UInt64(try takeByte())
            guard value >= 24 else { throw CBORError.nonCanonical }
            return value
        case 25:
            let value = try integer(byteCount: 2)
            guard value > UInt64(UInt8.max) else { throw CBORError.nonCanonical }
            return value
        case 26:
            let value = try integer(byteCount: 4)
            guard value > UInt64(UInt16.max) else { throw CBORError.nonCanonical }
            return value
        case 27:
            let value = try integer(byteCount: 8)
            guard value > UInt64(UInt32.max) else { throw CBORError.nonCanonical }
            return value
        default:
            throw CBORError.unsupported
        }
    }

    private mutating func integer(byteCount: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for byte in try take(byteCount) { value = (value << 8) | UInt64(byte) }
        return value
    }

    private mutating func takeByte() throws -> UInt8 {
        guard offset < bytes.count else { throw CBORError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset <= bytes.count - count else { throw CBORError.truncated }
        let start = offset
        offset += count
        return bytes[start..<offset]
    }
}

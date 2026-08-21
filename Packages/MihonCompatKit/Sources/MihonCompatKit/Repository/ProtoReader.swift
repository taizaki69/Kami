import Foundation

/// Minimal proto3 wire-format reader. Decodes into a generic field tree so
/// schemas can be consumed without code generation (index.pb, .tachibk).
public enum ProtoValue {
    case varint(UInt64)
    case lengthDelimited([UInt8])
    case fixed32(UInt32)
    case fixed64(UInt64)
    case groupStart(Int)
    case groupEnd(Int)

    public var stringValue: String? {
        if case let .lengthDelimited(bytes) = self {
            return String(decoding: bytes, as: UTF8.self)
        }
        return nil
    }

    public var int64Value: Int64? {
        if case let .varint(v) = self { return Int64(bitPattern: v) }
        return nil
    }

    public var floatValue: Float? {
        if case let .fixed32(v) = self { return Float(bitPattern: v) }
        return nil
    }

    public var bytesValue: [UInt8]? {
        if case let .lengthDelimited(b) = self { return b }
        return nil
    }

    public var message: ProtoMessage? {
        if case let .lengthDelimited(b) = self {
            return try? ProtoMessage(b)
        }
        return nil
    }
}

public struct ProtoMessage {
    /// Field number → values (repeated fields produce multiple entries).
    public let fields: [Int: [ProtoValue]]

    public init(_ bytes: [UInt8]) throws {
        var dict: [Int: [ProtoValue]] = [:]
        var r = ByteReader(bytes)

        while !r.isAtEnd {
            let tag = try r.uleb128()
            let fieldNumber = Int(tag >> 3)
            let wireType = tag & 0x7
            guard fieldNumber > 0 else { break }

            let value: ProtoValue
            switch wireType {
            case 0: value = .varint(try r.uleb128())
            case 1: value = .fixed64(try r.u64())
            case 2:
                let len = Int(try r.uleb128())
                value = .lengthDelimited(Array(try r.bytes(at: r.offset..<r.offset + len)))
                try r.skip(len)
            case 5: value = .fixed32(try r.u32())
            case 3: value = .groupStart(fieldNumber)
            case 4: value = .groupEnd(fieldNumber)
            default:
                throw ByteReader.Error.badULEB128(at: r.offset)
            }
            dict[fieldNumber, default: []].append(value)
        }
        self.fields = dict
    }

    public func first(_ field: Int) -> ProtoValue? { fields[field]?.first }
    public func string(_ field: Int) -> String? { first(field)?.stringValue }
    public func int64(_ field: Int) -> Int64? { first(field)?.int64Value }
    public func int(_ field: Int) -> Int? { first(field)?.int64Value.map(Int.init) }
    public func float(_ field: Int) -> Float? { first(field)?.floatValue }
    public func message(_ field: Int) -> ProtoMessage? { first(field)?.message }
    public func messages(_ field: Int) -> [ProtoMessage] {
        (fields[field] ?? []).compactMap(\.message)
    }
    public func strings(_ field: Int) -> [String] {
        (fields[field] ?? []).compactMap(\.stringValue)
    }
    /// Repeated varint field (e.g. BackupManga.categories).
    public func ints(_ field: Int) -> [Int] {
        (fields[field] ?? []).compactMap(\.int64Value).map(Int.init)
    }
}

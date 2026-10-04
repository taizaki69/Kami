import Foundation

/// A lexical pass before Foundation can allocate decoded objects. It validates
/// every UTF-8 scalar and JSON escape, counts values/decoded string bytes, and
/// detects equivalent escaped keys within each object without building a tree.
struct LibraryBackupJSONPreflight {
    private let bytes: [UInt8]
    private let policy: LibraryBackupPolicy
    private var index = 0
    private var values = 0
    private var stringBytes = 0
    private var nextCancellationCheck = 0

    init(data: Data, policy: LibraryBackupPolicy) throws {
        try Task.checkCancellation()
        guard data.count <= policy.maximumInputBytes else {
            throw LibraryBackupError.limitExceeded(.inputBytes)
        }
        bytes = Array(data)
        self.policy = policy
    }

    mutating func run() throws {
        try whitespace()
        try value(depth: 1)
        try whitespace()
        guard index == bytes.count else { throw LibraryBackupError.invalidJSON }
        try Task.checkCancellation()
    }

    private mutating func checkpoint() throws {
        if index >= nextCancellationCheck {
            try Task.checkCancellation()
            nextCancellationCheck = index + 2_048
        }
    }

    private mutating func whitespace() throws {
        while index < bytes.count {
            try checkpoint()
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func value(depth: Int) throws {
        try checkpoint()
        guard depth <= policy.maximumDepth else { throw LibraryBackupError.limitExceeded(.depth) }
        guard values < policy.maximumJSONValues else { throw LibraryBackupError.limitExceeded(.jsonValues) }
        values += 1
        guard index < bytes.count else { throw LibraryBackupError.invalidJSON }
        switch bytes[index] {
        case 0x7B: try object(depth: depth)
        case 0x5B: try array(depth: depth)
        case 0x22: _ = try string(capture: false)
        case 0x74: try literal([0x74, 0x72, 0x75, 0x65])
        case 0x66: try literal([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E: try literal([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39: try number()
        default: throw LibraryBackupError.invalidJSON
        }
    }

    private mutating func object(depth: Int) throws {
        index += 1
        try whitespace()
        if consume(0x7D) { return }
        var keys = Set<Data>()
        var normalizedKeys = Set<String>()
        while true {
            guard keys.count < policy.maximumJSONObjectKeys else {
                throw LibraryBackupError.limitExceeded(.jsonObjectKeys)
            }
            guard index < bytes.count, bytes[index] == 0x22 else { throw LibraryBackupError.invalidJSON }
            let key = try string(capture: true)
            guard keys.insert(key).inserted else { throw LibraryBackupError.duplicateJSONKey }
            // Foundation keys use Swift String equality. Reject its canonical
            // Unicode aliases before it can replace an exact JSON spelling.
            guard let normalizedKey = String(data: key, encoding: .utf8),
                  normalizedKeys.insert(normalizedKey).inserted else {
                throw LibraryBackupError.duplicateJSONKey
            }
            try whitespace()
            guard consume(0x3A) else { throw LibraryBackupError.invalidJSON }
            try whitespace()
            try value(depth: depth + 1)
            try whitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw LibraryBackupError.invalidJSON }
            try whitespace()
        }
    }

    private mutating func array(depth: Int) throws {
        index += 1
        try whitespace()
        if consume(0x5D) { return }
        var elements = 0
        while true {
            guard elements < policy.maximumJSONArrayElements else {
                throw LibraryBackupError.limitExceeded(.jsonArrayElements)
            }
            elements += 1
            try value(depth: depth + 1)
            try whitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw LibraryBackupError.invalidJSON }
            try whitespace()
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func literal(_ expected: [UInt8]) throws {
        guard expected.count <= bytes.count - index,
              bytes[index..<(index + expected.count)].elementsEqual(expected) else {
            throw LibraryBackupError.invalidJSON
        }
        index += expected.count
    }

    private mutating func number() throws {
        _ = consume(0x2D)
        guard index < bytes.count else { throw LibraryBackupError.invalidJSON }
        if consume(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) { throw LibraryBackupError.invalidJSON }
        } else {
            guard (0x31...0x39).contains(bytes[index]) else { throw LibraryBackupError.invalidJSON }
            try digits()
        }
        if consume(0x2E) {
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw LibraryBackupError.invalidJSON }
            try digits()
        }
        if consume(0x65) || consume(0x45) {
            if !consume(0x2B) { _ = consume(0x2D) }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw LibraryBackupError.invalidJSON }
            try digits()
        }
    }

    private mutating func digits() throws {
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            index += 1
            try checkpoint()
        }
    }

    private mutating func addStringBytes(_ amount: Int) throws {
        guard amount <= policy.maximumJSONStringBytes - stringBytes else {
            throw LibraryBackupError.limitExceeded(.jsonStringBytes)
        }
        stringBytes += amount
    }

    private mutating func string(capture: Bool) throws -> Data {
        index += 1 // opening quote, checked by caller
        var result = Data()
        while index < bytes.count {
            try checkpoint()
            let start = index
            let byte = bytes[index]
            index += 1
            if byte == 0x22 { return result }
            guard byte >= 0x20 else { throw LibraryBackupError.invalidJSON }
            if byte == 0x5C {
                guard index < bytes.count else { throw LibraryBackupError.invalidJSON }
                let escape = bytes[index]
                index += 1
                let scalar: UInt32
                switch escape {
                case 0x22, 0x5C, 0x2F: scalar = UInt32(escape)
                case 0x62: scalar = 0x08
                case 0x66: scalar = 0x0C
                case 0x6E: scalar = 0x0A
                case 0x72: scalar = 0x0D
                case 0x74: scalar = 0x09
                case 0x75:
                    let first = try hexScalar()
                    if (0xD800...0xDBFF).contains(first) {
                        guard consume(0x5C), consume(0x75) else { throw LibraryBackupError.invalidJSON }
                        let second = try hexScalar()
                        guard (0xDC00...0xDFFF).contains(second) else { throw LibraryBackupError.invalidJSON }
                        scalar = 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00
                    } else {
                        guard !(0xDC00...0xDFFF).contains(first) else { throw LibraryBackupError.invalidJSON }
                        scalar = first
                    }
                default: throw LibraryBackupError.invalidJSON
                }
                guard let unicode = UnicodeScalar(scalar) else { throw LibraryBackupError.invalidJSON }
                let decoded = String(unicode).utf8
                try addStringBytes(decoded.count)
                if capture { result.append(contentsOf: decoded) }
            } else if byte < 0x80 {
                try addStringBytes(1)
                if capture { result.append(byte) }
            } else {
                let width: Int
                switch byte {
                case 0xC2...0xDF: width = 2
                case 0xE0...0xEF: width = 3
                case 0xF0...0xF4: width = 4
                default: throw LibraryBackupError.invalidJSON
                }
                guard width <= bytes.count - start else { throw LibraryBackupError.invalidJSON }
                let second = bytes[start + 1]
                guard (0x80...0xBF).contains(second),
                      !(byte == 0xE0 && second < 0xA0),
                      !(byte == 0xED && second >= 0xA0),
                      !(byte == 0xF0 && second < 0x90),
                      !(byte == 0xF4 && second >= 0x90) else { throw LibraryBackupError.invalidJSON }
                if width > 2 {
                    for offset in 2..<width {
                        guard (0x80...0xBF).contains(bytes[start + offset]) else { throw LibraryBackupError.invalidJSON }
                    }
                }
                index = start + width
                try addStringBytes(width)
                if capture { result.append(contentsOf: bytes[start..<index]) }
            }
        }
        throw LibraryBackupError.invalidJSON
    }

    private mutating func hexScalar() throws -> UInt32 {
        guard 4 <= bytes.count - index else { throw LibraryBackupError.invalidJSON }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
            default: throw LibraryBackupError.invalidJSON
            }
            value = value * 16 + digit
        }
        return value
    }
}

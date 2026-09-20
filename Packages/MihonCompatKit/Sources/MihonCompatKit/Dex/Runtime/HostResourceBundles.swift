import Foundation

private final class APKResourceStream {
    let bytes: [UInt8]
    var consumed = false
    var closed = false

    init(_ bytes: [UInt8]) { self.bytes = bytes }
}

private struct APKResourceReader {
    let stream: APKResourceStream
    let latin1: Bool
}

/// The line/escape grammar used by java.util.Properties.load(Reader).
/// UTF-16 keys preserve Java's exact equality, including canonically distinct
/// Unicode spellings. Input bytes and entry counts are independently bounded.
private struct JavaPropertyTable {
    var entries: [[UInt16]: [UInt16]] = [:]

    init(_ text: String) throws {
        let units = Array(text.utf16)
        guard units.count <= InterpretedAPKResources.maximumResourceBytes else {
            throw VMError.verify("resource property text exceeds limit")
        }
        var cursor = 0
        var logical: [UInt16] = []
        var continued = false
        while cursor < units.count {
            let start = cursor
            while cursor < units.count && units[cursor] != 10 && units[cursor] != 13 {
                cursor += 1
            }
            var line = units[start..<cursor]
            if cursor < units.count {
                let terminator = units[cursor]
                cursor += 1
                if terminator == 13 && cursor < units.count && units[cursor] == 10 { cursor += 1 }
            }
            while let first = line.first, Self.whitespace(first) { line = line.dropFirst() }
            if !continued && (line.isEmpty || line.first == 35 || line.first == 33) { continue }
            logical.append(contentsOf: line)
            let slashCount = line.reversed().prefix(while: { $0 == 92 }).count
            continued = slashCount % 2 == 1
            if continued { logical.removeLast() }
            if !continued {
                try insert(logical)
                logical.removeAll(keepingCapacity: true)
            }
        }
        if continued || !logical.isEmpty { try insert(logical) }
    }

    private mutating func insert(_ line: [UInt16]) throws {
        var keyEnd = 0
        var escaped = false
        while keyEnd < line.count {
            let unit = line[keyEnd]
            if !escaped && (unit == 61 || unit == 58 || Self.whitespace(unit)) { break }
            escaped = unit == 92 ? !escaped : false
            keyEnd += 1
        }
        var valueStart = keyEnd
        while valueStart < line.count && Self.whitespace(line[valueStart]) { valueStart += 1 }
        if valueStart < line.count && (line[valueStart] == 61 || line[valueStart] == 58) {
            valueStart += 1
        }
        while valueStart < line.count && Self.whitespace(line[valueStart]) { valueStart += 1 }
        let key = try Self.unescape(line[..<keyEnd])
        let value = try Self.unescape(line[valueStart...])
        // The current VM stores strings in Swift. Reject unpaired UTF-16
        // surrogates rather than silently replacing Java property contents.
        guard String(decoding: key, as: UTF16.self).utf16.elementsEqual(key),
              String(decoding: value, as: UTF16.self).utf16.elementsEqual(value) else {
            throw VMError.verify("resource property contains unsupported unpaired surrogate")
        }
        guard entries[key] != nil || entries.count < 2_048 else {
            throw VMError.verify("resource property table exceeds 2048 entries")
        }
        entries[key] = value
    }

    private static func whitespace(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9 || unit == 12
    }

    private static func unescape(_ raw: ArraySlice<UInt16>) throws -> [UInt16] {
        var result: [UInt16] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            var unit = raw[index]
            index += 1
            if unit == 92 && index < raw.endIndex {
                unit = raw[index]
                index += 1
                switch unit {
                case 116: unit = 9
                case 110: unit = 10
                case 114: unit = 13
                case 102: unit = 12
                case 117:
                    guard raw.endIndex - index >= 4 else { throw malformedEscape() }
                    unit = 0
                    for _ in 0..<4 {
                        let digit = raw[index]
                        index += 1
                        let value: UInt16
                        switch digit {
                        case 48...57: value = digit - 48
                        case 65...70: value = digit - 55
                        case 97...102: value = digit - 87
                        default: throw malformedEscape()
                        }
                        unit = (unit << 4) | value
                    }
                default: break
                }
            }
            result.append(unit)
        }
        return result
    }

    private static func malformedEscape() -> DEXThrowable {
        resourceThrowable("Ljava/lang/IllegalArgumentException;", "malformed resource Unicode escape")
    }
}

private func resourceThrowable(_ descriptor: String, _ message: String) -> DEXThrowable {
    DEXThrowable(.obj(ObjInstance(dexType: descriptor, payload: message, isHost: true)))
}

private func resourceArgument(_ args: [RVal], _ index: Int) throws -> RVal {
    guard args.indices.contains(index) else { throw VMError.verify("resource argument missing") }
    guard !args[index].isNull else {
        throw resourceThrowable("Ljava/lang/NullPointerException;", "null resource argument")
    }
    return args[index]
}

private func resourceString(_ args: [RVal], _ index: Int) throws -> String {
    guard case let .obj(object) = try resourceArgument(args, index),
          object.dexType == "Ljava/lang/String;", let value = object.payload as? String else {
        throw VMError.verify("resource string argument")
    }
    return value
}

extension HostBridge {
    static func registerResourceBundleSurface(_ bridge: HostBridge, resources: InterpretedAPKResources) {
        let loaderType = "Ljava/lang/ClassLoader;"
        let streamType = "Ljava/io/InputStream;"
        let readerType = "Ljava/io/InputStreamReader;"
        let bundleType = "Ljava/util/PropertyResourceBundle;"
        let loader = RVal.obj(ObjInstance(dexType: loaderType, isHost: true))
        bridge.register(class: "Ljava/lang/Class;", "getClassLoader", prototype: "()Ljava/lang/ClassLoader;") { vm, args in
            guard case let .obj(object) = try resourceArgument(args, 0),
                  object.dexType == "Ljava/lang/Class;", let descriptor = object.payload as? String else {
                throw VMError.verify("Class.getClassLoader receiver")
            }
            let component = String(descriptor.drop(while: { $0 == "[" }))
            // Host/bootstrap classes do not acquire the extension's resource capability.
            return vm.dex.classIndexByDescriptor[component] == nil ? .null : loader
        }
        bridge.register(class: loaderType, "getResourceAsStream", prototype: "(Ljava/lang/String;)Ljava/io/InputStream;") { _, args in
            guard try resourceArgument(args, 0) === loader else {
                throw VMError.verify("resource class loader identity")
            }
            let path = try resourceString(args, 1)
            guard let bytes = resources.bytes(named: path) else { return .null }
            return .obj(ObjInstance(dexType: streamType, payload: APKResourceStream(bytes), isHost: true))
        }
        bridge.objectFactories[readerType] = { _ in .obj(ObjInstance(dexType: readerType, isHost: true)) }
        bridge.register(class: readerType, "<init>", prototype: "(Ljava/io/InputStream;Ljava/lang/String;)V") { _, args in
            guard case let .obj(reader) = try resourceArgument(args, 0),
                  case let .obj(input) = try resourceArgument(args, 1),
                  let stream = input.payload as? APKResourceStream else {
                throw VMError.verify("InputStreamReader resource arguments")
            }
            let encoding = try resourceString(args, 2).lowercased()
            let latin1: Bool
            switch encoding {
            case "utf-8", "utf8": latin1 = false
            case "iso-8859-1", "iso8859-1", "iso8859_1", "iso_8859_1", "latin1": latin1 = true
            default:
                throw resourceThrowable("Ljava/io/UnsupportedEncodingException;", "unsupported resource encoding")
            }
            reader.payload = APKResourceReader(stream: stream, latin1: latin1)
            return .null
        }
        bridge.objectFactories[bundleType] = { _ in .obj(ObjInstance(dexType: bundleType, isHost: true)) }
        bridge.register(class: bundleType, "<init>", prototype: "(Ljava/io/Reader;)V") { _, args in
            guard case let .obj(bundle) = try resourceArgument(args, 0),
                  case let .obj(reader) = try resourceArgument(args, 1),
                  let input = reader.payload as? APKResourceReader else {
                throw VMError.verify("PropertyResourceBundle resource reader")
            }
            guard !input.stream.closed else {
                throw resourceThrowable("Ljava/io/IOException;", "resource stream is closed")
            }
            let bytes = input.stream.consumed ? [] : input.stream.bytes
            input.stream.consumed = true
            let text = input.latin1
                ? String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
                : String(decoding: bytes, as: UTF8.self)
            bundle.payload = try JavaPropertyTable(text)
            return .null
        }
        for method in ["containsKey", "getString"] {
            bridge.register(
                class: "Ljava/util/ResourceBundle;", method,
                prototype: method == "containsKey" ? "(Ljava/lang/String;)Z" : "(Ljava/lang/String;)Ljava/lang/String;"
            ) { _, args in
                guard case let .obj(bundle) = try resourceArgument(args, 0),
                      let table = bundle.payload as? JavaPropertyTable else {
                    throw VMError.verify("ResourceBundle receiver")
                }
                let key = Array(try resourceString(args, 1).utf16)
                let value = table.entries[key]
                if method == "containsKey" { return .int(value == nil ? 0 : 1) }
                guard let value else {
                    throw resourceThrowable("Ljava/util/MissingResourceException;", "resource key is missing")
                }
                return string(String(decoding: value, as: UTF16.self))
            }
        }
        for descriptor in [streamType, readerType, "Ljava/io/Reader;", "Ljava/io/Closeable;"] {
            bridge.register(class: descriptor, "close", prototype: "()V") { _, args in
                guard case let .obj(object) = try resourceArgument(args, 0) else {
                    throw VMError.verify("resource close receiver")
                }
                if let stream = object.payload as? APKResourceStream {
                    stream.closed = true
                } else if let reader = object.payload as? APKResourceReader {
                    reader.stream.closed = true
                } else {
                    throw VMError.verify("resource close receiver")
                }
                return .null
            }
        }
    }
}

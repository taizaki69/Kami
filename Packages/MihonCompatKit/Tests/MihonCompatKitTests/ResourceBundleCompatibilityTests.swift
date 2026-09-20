import XCTest
@testable import MihonCompatKit

final class ResourceBundleCompatibilityTests: XCTestCase {
    private func makeVM(_ contents: [String: [UInt8]]) throws -> (DexInterpreter, HostBridge, RVal) {
        var builder = DexBuilder()
        builder.setClass("LResourceTest;")
        builder.addMethod(.init(name: "noop", registers: 0, ins: 0, outs: 0, insns: [0x000e], isStatic: true))
        let bridge = HostBridge.minimal(resources: try InterpretedAPKResources(contents: contents))
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge)
        let loader = try invoke(bridge, vm, "Ljava/lang/Class;", "getClassLoader", "()Ljava/lang/ClassLoader;", [
            .obj(ObjInstance(dexType: "Ljava/lang/Class;", payload: "LResourceTest;", isHost: true)),
        ])
        return (vm, bridge, loader)
    }

    private func invoke(
        _ bridge: HostBridge, _ vm: DexInterpreter, _ owner: String,
        _ name: String, _ prototype: String, _ args: [RVal]
    ) throws -> RVal {
        let method = try XCTUnwrap(bridge.resolve(class: owner, name, prototype: prototype, isStatic: false))
        return try method(vm, args)
    }

    private func reader(
        _ path: String, _ vm: DexInterpreter, _ bridge: HostBridge, _ loader: RVal,
        encoding: String = "UTF-8"
    ) throws -> RVal {
        let stream = try invoke(bridge, vm, "Ljava/lang/ClassLoader;", "getResourceAsStream",
                                "(Ljava/lang/String;)Ljava/io/InputStream;", [loader, HostBridge.string(path)])
        let factory = try XCTUnwrap(bridge.objectFactories["Ljava/io/InputStreamReader;"])
        let reader = try factory(vm)
        _ = try invoke(bridge, vm, "Ljava/io/InputStreamReader;", "<init>",
                       "(Ljava/io/InputStream;Ljava/lang/String;)V", [reader, stream, HostBridge.string(encoding)])
        return reader
    }

    private func bundle(_ reader: RVal, _ vm: DexInterpreter, _ bridge: HostBridge) throws -> RVal {
        let factory = try XCTUnwrap(bridge.objectFactories["Ljava/util/PropertyResourceBundle;"])
        let value = try factory(vm)
        _ = try invoke(bridge, vm, "Ljava/util/PropertyResourceBundle;", "<init>",
                       "(Ljava/io/Reader;)V", [value, reader])
        return value
    }

    private func value(_ key: String, _ bundle: RVal, _ vm: DexInterpreter, _ bridge: HostBridge) throws -> String {
        vmStringValue(try invoke(bridge, vm, "Ljava/util/ResourceBundle;", "getString",
                                 "(Ljava/lang/String;)Ljava/lang/String;", [bundle, HostBridge.string(key)]))
    }

    private func assertThrowable(_ error: Error, _ descriptor: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let thrown = error as? DEXThrowable, case let .obj(object) = thrown.value else {
            return XCTFail("expected DEX throwable, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(object.dexType, descriptor, file: file, line: line)
    }

    func testBundledPropertiesPreserveJavaGrammarAndRemainSourceScoped() throws {
        let path = "assets/i18n/messages_en.properties"
        let text = #"""
          # comment ends even with a backslash \
        standalone
        key\ with\ spaces\ \:=first\
            second
        escaped=\t\n\r\f\q\!\#
        emoji=\uD83D\uDE00
        accent\u00e9=precomposed
        accente\u0301=decomposed
        duplicate=old
         duplicate : new
        =empty key
        """# + "\r\ntrailing=keep \r\nend=last\\"
        let (vm, bridge, loader) = try makeVM([path: Array(text.utf8)])
        let input = try reader(path, vm, bridge, loader)
        let result = try bundle(input, vm, bridge)
        for (key, expected) in [
            ("standalone", ""), ("key with spaces :", "firstsecond"),
            ("escaped", "\t\n\r\u{c}q!#"), ("emoji", "😀"),
            ("accenté", "precomposed"), ("accente\u{301}", "decomposed"),
            ("duplicate", "new"), ("", "empty key"), ("trailing", "keep "), ("end", "last"),
        ] {
            XCTAssertEqual(try value(key, result, vm, bridge), expected)
        }
        let exhausted = try bundle(input, vm, bridge)
        XCTAssertThrowsError(try value("duplicate", exhausted, vm, bridge)) {
            self.assertThrowable($0, "Ljava/util/MissingResourceException;")
        }
        let (otherVM, otherBridge, otherLoader) = try makeVM([path: Array("duplicate=other".utf8)])
        let other = try bundle(reader(path, otherVM, otherBridge, otherLoader), otherVM, otherBridge)
        XCTAssertEqual(try value("duplicate", other, otherVM, otherBridge), "other")
        XCTAssertEqual(try value("duplicate", result, vm, bridge), "new")
        XCTAssertThrowsError(try invoke(otherBridge, otherVM, "Ljava/lang/ClassLoader;", "getResourceAsStream",
                                        "(Ljava/lang/String;)Ljava/io/InputStream;", [loader, HostBridge.string(path)]))
        for missing in ["missing", "../secret", "/etc/passwd", "C:\\secret", "https://example.test/file", "assets/../file"] {
            XCTAssertTrue(try invoke(bridge, vm, "Ljava/lang/ClassLoader;", "getResourceAsStream",
                                     "(Ljava/lang/String;)Ljava/io/InputStream;", [loader, HostBridge.string(missing)]).isNull)
        }
        let bootstrap = try invoke(bridge, vm, "Ljava/lang/Class;", "getClassLoader", "()Ljava/lang/ClassLoader;", [
            .obj(ObjInstance(dexType: "Ljava/lang/Class;", payload: "Ljava/lang/String;", isHost: true)),
        ])
        XCTAssertTrue(bootstrap.isNull)
        XCTAssertNil(bridge.resolve(class: "Ljava/lang/ClassLoader;", "loadClass",
                                   prototype: "(Ljava/lang/String;)Ljava/lang/Class;", isStatic: false))
    }

    func testResourceBoundsMalformedEscapesAndReaderLifecycleFailExplicitly() throws {
        let path = "assets/i18n/test.properties"
        for malformed in [#"key=\u12G4"#, #"key=\u123"#, #"key=\uu0061"#] {
            let (vm, bridge, loader) = try makeVM([path: Array(malformed.utf8)])
            let input = try reader(path, vm, bridge, loader)
            XCTAssertThrowsError(try bundle(input, vm, bridge)) {
                self.assertThrowable($0, "Ljava/lang/IllegalArgumentException;")
            }
        }
        for unsupported in [#"key=\uD800"#, #"\uDC00=value"#] {
            let (vm, bridge, loader) = try makeVM([path: Array(unsupported.utf8)])
            XCTAssertThrowsError(try bundle(reader(path, vm, bridge, loader), vm, bridge)) {
                guard case VMError.verify = $0 else { return XCTFail("expected unsupported UTF-16 rejection") }
            }
        }
        let (vm, bridge, loader) = try makeVM([path: Array("key=".utf8) + [0xE9]])
        let input = try reader(path, vm, bridge, loader, encoding: "ISO-8859-1")
        XCTAssertEqual(try value("key", bundle(input, vm, bridge), vm, bridge), "é")
        let closed = try reader(path, vm, bridge, loader)
        _ = try invoke(bridge, vm, "Ljava/io/Reader;", "close", "()V", [closed])
        XCTAssertThrowsError(try bundle(closed, vm, bridge)) { self.assertThrowable($0, "Ljava/io/IOException;") }
        XCTAssertThrowsError(try reader(path, vm, bridge, loader, encoding: "unknown-encoding")) {
            self.assertThrowable($0, "Ljava/io/UnsupportedEncodingException;")
        }
        let oversizedTable = (0..<2_049).map { "key\($0)=value" }.joined(separator: "\n")
        let (limitVM, limitBridge, limitLoader) = try makeVM([path: Array(oversizedTable.utf8)])
        XCTAssertThrowsError(try bundle(reader(path, limitVM, limitBridge, limitLoader), limitVM, limitBridge)) {
            guard case VMError.verify = $0 else { return XCTFail("expected property entry limit") }
        }
        XCTAssertThrowsError(try InterpretedAPKResources(contents: ["../outside": []])) {
            XCTAssertEqual($0 as? InterpretedAPKResources.Error, .invalidPath)
        }
        XCTAssertThrowsError(try InterpretedAPKResources(contents: [path: Array(repeating: 0, count: 256 * 1024 + 1)])) {
            XCTAssertEqual($0 as? InterpretedAPKResources.Error, .resourceTooLarge)
        }
        XCTAssertThrowsError(try InterpretedAPKResources(contents: Dictionary(uniqueKeysWithValues:
            (0..<65).map { ("entry\($0)", [UInt8]()) }
        ))) { XCTAssertEqual($0 as? InterpretedAPKResources.Error, .tooManyResources) }
        XCTAssertThrowsError(try InterpretedAPKResources(contents: Dictionary(uniqueKeysWithValues:
            (0..<5).map { ("entry\($0)", Array(repeating: UInt8(0), count: 256 * 1024)) }
        ))) { XCTAssertEqual($0 as? InterpretedAPKResources.Error, .totalSizeExceeded) }
    }
}

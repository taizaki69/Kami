// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MihonCompatKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MihonCompatKit", targets: ["MihonCompatKit"]),
        .executable(name: "compat-audit", targets: ["CompatAudit"]),
    ],
    dependencies: [
        // 2.9.6 is the newest SwiftSoup release whose package manifest keeps
        // Kami's Swift 5.9/Xcode 15 minimum. Pin exactly for reproducible
        // extension-runtime parsing behavior.
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.9.6"),
        // 3.12.5 is the newest Swift Crypto release with a Swift 5.9 package
        // manifest. It supplies cross-platform SHA-256 for pinned APK gates.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.5"),
    ],
    targets: [
        .target(
            name: "MihonCompatKit",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "CompatAudit",
            dependencies: ["MihonCompatKit"],
            path: "Sources/CompatAudit"
        ),
        .testTarget(name: "MihonCompatKitTests", dependencies: ["MihonCompatKit"]),
    ]
)

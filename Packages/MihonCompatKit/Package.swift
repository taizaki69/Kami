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
    targets: [
        .target(name: "MihonCompatKit"),
        .executableTarget(
            name: "CompatAudit",
            dependencies: ["MihonCompatKit"],
            path: "Sources/CompatAudit"
        ),
        .testTarget(name: "MihonCompatKitTests", dependencies: ["MihonCompatKit"]),
    ]
)

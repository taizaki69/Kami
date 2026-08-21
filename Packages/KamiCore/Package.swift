// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KamiCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "KamiCore", targets: ["KamiCore"]),
    ],
    dependencies: [
        .package(path: "../MihonCompatKit"),
    ],
    targets: [
        .target(name: "KamiCore", dependencies: ["MihonCompatKit"]),
        .testTarget(name: "KamiCoreTests", dependencies: ["KamiCore"]),
    ]
)

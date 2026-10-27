// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeskKei",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DeskKei", targets: ["DeskKei"]),
    ],
    targets: [
        .target(name: "DeskKeiCore"),
        .executableTarget(name: "DeskKei", dependencies: ["DeskKeiCore"]),
        .testTarget(name: "DeskKeiCoreTests", dependencies: ["DeskKeiCore"]),
    ]
)

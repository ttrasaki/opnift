// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Opnift",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(name: "Opnift", targets: ["Opnift"]),
    ],
    targets: [
        .target(
            name: "Opnift"
        ),
        .executableTarget(
            name: "opnift-render",
            dependencies: ["Opnift"]
        ),
        .testTarget(
            name: "OpniftTests",
            dependencies: ["Opnift"]
        ),
    ]
)

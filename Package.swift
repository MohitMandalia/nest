// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Nest",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Nest", targets: ["NestLauncher"]),
               .executable(name: "NestBackground", targets: ["NestBackground"])],
    targets: [
        .target(name: "NestCore"),
        .target(name: "Nest", dependencies: ["NestCore"], resources: [.process("Resources")]),
        .executableTarget(name: "NestLauncher", dependencies: ["Nest"]),
        .executableTarget(name: "NestBackground", dependencies: ["Nest"]),
        .testTarget(name: "NestCoreTests", dependencies: ["NestCore"]),
        .testTarget(name: "NestAppTests", dependencies: ["Nest", "NestCore"])
    ]
)

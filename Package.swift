// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StayUp",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "StayUpApp", targets: ["StayUpApp"]),
        .executable(name: "stay-up", targets: ["StayUpCLI"]),
        .executable(name: "StayUpHelper", targets: ["StayUpHelper"]),
        .library(name: "StayUpCore", targets: ["StayUpCore"]),
    ],
    targets: [
        .target(name: "StayUpCore"),
        .target(name: "StayUpService", dependencies: ["StayUpCore"]),
        .executableTarget(name: "StayUpApp", dependencies: ["StayUpCore", "StayUpService"]),
        .executableTarget(name: "StayUpCLI", dependencies: ["StayUpCore"]),
        .executableTarget(name: "StayUpHelper", dependencies: ["StayUpCore"]),
        .testTarget(name: "StayUpCoreTests", dependencies: ["StayUpCore"]),
        .testTarget(name: "StayUpServiceTests", dependencies: ["StayUpService", "StayUpCore"]),
    ]
)

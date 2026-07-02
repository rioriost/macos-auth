// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacosAuthAgent",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "macos-auth-agent", targets: ["MacosAuthAgent"])
    ],
    targets: [
        .executableTarget(
            name: "MacosAuthAgent",
            dependencies: []
        )
    ]
)

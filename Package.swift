// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacConsoleHost",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacConsoleHost", targets: ["MacConsoleHost"])
    ],
    targets: [
        .executableTarget(
            name: "MacConsoleHost",
            path: "Sources/MacConsoleHost"
        )
    ]
)

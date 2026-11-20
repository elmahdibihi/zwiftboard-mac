// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZwiftBoardMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ZwiftBoardCore", targets: ["ZwiftBoardCore"]),
        .executable(name: "ZwiftBoard", targets: ["ZwiftBoardApp"])
    ],
    targets: [
        .target(
            name: "ZwiftBoardCore",
            path: "Sources/ZwiftBoardCore"
        ),
        .executableTarget(
            name: "ZwiftBoardApp",
            dependencies: ["ZwiftBoardCore"],
            path: "Sources/ZwiftBoardApp"
        )
    ]
)

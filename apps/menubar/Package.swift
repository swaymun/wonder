// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WonderMenu",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        .package(path: "../../native/computer-use"),
    ],
    targets: [
        .executableTarget(name: "WonderMenu", dependencies: [
            .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "WonderComputerUseCore", package: "computer-use"),
        ], path: "Sources/WonderMenu", linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(
            name: "WonderMenuTests",
            dependencies: ["WonderMenu"],
            path: "Tests/WonderMenuTests"
        )
    ]
)

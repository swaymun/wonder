// swift-tools-version: 6.0
import PackageDescription
import Foundation

let relayLibrarySettings: [LinkerSetting] = {
    guard let directory = ProcessInfo.processInfo.environment["WONDER_RELAY_LIB_DIR"], !directory.isEmpty else {
        return []
    }
    return [.unsafeFlags(["-L", directory, "-lwonder_relay_ffi"])]
}()

let package = Package(
    name: "WonderNativeRelay",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "WonderNativeRelay", targets: ["WonderNativeRelay"])
    ],
    targets: [
        .target(
            name: "WonderRelayFFI",
            path: "Sources/WonderRelayFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "WonderNativeRelay",
            dependencies: ["WonderRelayFFI"],
            path: "Sources/WonderNativeRelay",
            linkerSettings: relayLibrarySettings
        ),
        .testTarget(
            name: "WonderNativeRelayTests",
            dependencies: ["WonderNativeRelay"],
            path: "Tests/WonderNativeRelayTests"
        )
    ]
)

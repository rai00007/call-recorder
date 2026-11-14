// swift-tools-version: 6.0
// Used only for `swift test` (non-UI logic). The app itself is built by ./build.sh with swiftc.
import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CallRecorderCore", path: "CallRecorder", exclude: ["App", "Views", "MenuBar", "Prompts"]),
        .testTarget(name: "CallRecorderTests", dependencies: ["CallRecorderCore"], path: "Tests/CallRecorderTests"),
    ],
    swiftLanguageModes: [.v5]
)

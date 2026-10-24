// swift-tools-version: 6.0
import PackageDescription

// SheafsKit: the platform-independent core of Sheafs (EPUB container, text model,
// OPDS, KOReader sync). Foundation + Compression + CryptoKit only, so `swift test`
// runs on the Mac without a simulator.
let package = Package(
    name: "SheafsKit",
    platforms: [.iOS("27.1"), .macOS("15.0")],
    products: [
        .library(name: "SheafsKit", targets: ["SheafsKit"]),
        .executable(name: "sheafs-cli", targets: ["SheafsCLI"]),
    ],
    targets: [
        .target(
            name: "SheafsKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SheafsCLI",
            dependencies: ["SheafsKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SheafsKitTests",
            dependencies: ["SheafsKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

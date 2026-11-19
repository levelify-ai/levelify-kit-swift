// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "levelify-kit-swift",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LevelifyKit", targets: ["LevelifyKit"]),
        .library(name: "LevelifyPlayerHost", targets: ["LevelifyPlayerHost"]),
        .library(name: "LevelifyKitTesting", targets: ["LevelifyKitTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.3"),
    ],
    targets: [
        .target(
            name: "LevelifyKit",
            dependencies: [
                .product(
                    name: "Supabase",
                    package: "supabase-swift",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
            ],
            path: "Sources/LevelifyKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LevelifyPlayerHost",
            dependencies: ["LevelifyKit"],
            path: "Sources/LevelifyPlayerHost",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LevelifyKitTesting",
            dependencies: ["LevelifyKit"],
            path: "Sources/LevelifyKitTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LevelifyKitTests",
            dependencies: ["LevelifyKit", "LevelifyPlayerHost", "LevelifyKitTesting"],
            path: "Tests/LevelifyKitTests",
            resources: [
                .process("Fixtures"),
                .copy("BridgeFixtures"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

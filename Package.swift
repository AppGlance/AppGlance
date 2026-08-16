// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppGlance",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AppGlance", targets: ["AppGlance"])
    ],
    targets: [
        .target(
            name: "AppGlance",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "AppGlanceTests",
            dependencies: ["AppGlance"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)

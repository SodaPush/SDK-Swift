// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SodaPush",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "SodaPush",
            targets: ["SodaPush"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/guoPhineas/RuntimeSecretMacro.git",
            revision: "d6e7b92557bab0f08e9b231e1c9a0e82364de7b4"
        ),
    ],
    targets: [
        .target(
            name: "SodaPush",
            dependencies: [
                .product(name: "RuntimeSecretMacro", package: "RuntimeSecretMacro"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "SodaPushTests",
            dependencies: ["SodaPush"]
        ),
    ]
)

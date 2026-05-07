// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipRavenSync",
    defaultLocalization: "ko",
    platforms: [
        // Mac app deployment target is 13.0; CKSyncEngine code inside the package
        // is gated with @available(macOS 14.0, iOS 17.0, *) so older callers can
        // still link the module. iOS app deployment target is 17.0.
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "ClipRavenSync",
            targets: ["ClipRavenSync"]
        ),
    ],
    dependencies: [
        // GRDB pinned to the same major version Mac app uses.
        // Update both in lockstep.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
        // xxHash for cross-device hash unification — Mac과 iOS가 같은
        // contentHash를 계산할 수 있도록 hash 알고리즘을 패키지에서 공유.
        .package(url: "https://github.com/daisuke-t-jp/xxHash-Swift", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "ClipRavenSync",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "xxHash-Swift", package: "xxHash-Swift"),
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ClipRavenSyncTests",
            dependencies: ["ClipRavenSync"]
        ),
    ]
)

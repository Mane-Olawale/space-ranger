// swift-tools-version: 6.0
// ReclaimKit — library targets + CLI/bench executables for Reclaim (PLAN.md §2.3, §6 Phase 0).
import PackageDescription

/// Applied to every target: Swift 6 language mode already implies `-strict-concurrency=complete`;
/// the upcoming-feature flag is kept explicit per PLAN.md, and warnings are errors in Debug builds
/// (Release builds keep warnings visible without failing packaging).
let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .unsafeFlags(["-warnings-as-errors"], .when(configuration: .debug)),
]

let argumentParser: Target.Dependency = .product(name: "ArgumentParser", package: "swift-argument-parser")

let package = Package(
    name: "ReclaimKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReclaimCore", targets: ["ReclaimCore"]),
        .library(name: "ReclaimSafety", targets: ["ReclaimSafety"]),
        .library(name: "ReclaimPersistence", targets: ["ReclaimPersistence"]),
        .library(name: "ReclaimRules", targets: ["ReclaimRules"]),
        .library(name: "ReclaimXPC", targets: ["ReclaimXPC"]),
        .library(name: "ReclaimTestSupport", targets: ["ReclaimTestSupport"]),
        .executable(name: "reclaim", targets: ["ReclaimCLI"]),
        .executable(name: "reclaim-bench", targets: ["ReclaimBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Dependency direction (PLAN.md §2.3):
        // ReclaimCore ← ReclaimSafety ← ReclaimRules ← { ReclaimCLI, ReclaimUI }
        // ReclaimPersistence → ReclaimCore only; ReclaimXPC → nothing.
        .target(name: "ReclaimCore", swiftSettings: strictSettings),
        .target(name: "ReclaimSafety", dependencies: ["ReclaimCore"], swiftSettings: strictSettings),
        .target(name: "ReclaimPersistence", dependencies: ["ReclaimCore"], swiftSettings: strictSettings),
        .target(name: "ReclaimRules", dependencies: ["ReclaimCore", "ReclaimSafety"], swiftSettings: strictSettings),
        .target(name: "ReclaimXPC", swiftSettings: strictSettings),

        // Test support: real-APFS fixture builder + Swift Testing tags. It imports `Testing`, so it
        // must only be linked by test targets (see docs/ADR/ADR-012-test-support-isolation.md).
        .target(name: "ReclaimTestSupport", swiftSettings: strictSettings),

        .executableTarget(
            name: "ReclaimCLI",
            dependencies: ["ReclaimCore", "ReclaimSafety", "ReclaimPersistence", "ReclaimRules", argumentParser],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "ReclaimBench",
            dependencies: [argumentParser],
            swiftSettings: strictSettings
        ),

        .testTarget(
            name: "ReclaimTestSupportTests",
            dependencies: ["ReclaimTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ReclaimBenchTests",
            dependencies: ["ReclaimTestSupport"],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

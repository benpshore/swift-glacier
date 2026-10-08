// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift_glacier",
    targets: [
        .target(name: "swift_glacier"),
        .testTarget(
            name: "swift_glacierTests",
            dependencies: ["swift_glacier"]
            , path: "SwiftTests"  // tests/ is Python's; macOS disks ignore case
        )
    ]
)

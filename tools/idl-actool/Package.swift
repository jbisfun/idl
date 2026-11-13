// swift-tools-version: 6.0
// idl-actool: a thin command-line wrapper around xtool-org/AssetKit, which
// compiles .xcassets catalogs into Assets.car on Linux. Built by `zig build`
// and installed next to `idl`.
import PackageDescription

let package = Package(
    name: "idl-actool",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/xtool-org/AssetKit", exact: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "idl-actool",
            dependencies: [.product(name: "AssetKit", package: "AssetKit")]
        ),
    ]
)

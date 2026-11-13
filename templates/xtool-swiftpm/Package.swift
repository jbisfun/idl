// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XtoolExample",
    platforms: [.iOS(.v16)],
    products: [.library(name: "XtoolExample", targets: ["XtoolExample"])],
    targets: [
        .target(
            name: "XtoolExample",
            path: "Sources/XtoolExample",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("UIKit")]
        ),
    ]
)

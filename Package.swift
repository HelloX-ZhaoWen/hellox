// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HelloX",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HelloXCore", targets: ["HelloXCore"]),
        .executable(name: "HelloX", targets: ["HelloXApp"])
    ],
    targets: [
        .target(
            name: "HelloXCore",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("Security"),
                .linkedFramework("Accelerate")
            ]
        ),
        .executableTarget(
            name: "HelloXApp",
            dependencies: ["HelloXCore"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Translation"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "HelloXCoreTests",
            dependencies: ["HelloXCore"]
        ),
        .testTarget(
            name: "HelloXAppTests",
            dependencies: ["HelloXApp"]
        )
    ]
)

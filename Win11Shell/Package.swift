// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Win11Shell",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "Win11ShellCore", targets: ["Win11ShellCore"]),
        .executable(name: "Win11ShellApp", targets: ["Win11ShellApp"])
    ],
    targets: [
        .target(
            name: "Win11ShellCore",
            dependencies: []
        ),
        .executableTarget(
            name: "Win11ShellApp",
            dependencies: ["Win11ShellCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "Win11ShellCoreTests",
            dependencies: ["Win11ShellCore"]
        )
    ]
)

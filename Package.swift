// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "FileExplorerCore", targets: ["FileExplorerCore"]),
        .library(name: "FileExplorerDesign", targets: ["FileExplorerDesign"]),
        .library(name: "FileExplorerChrome", targets: ["FileExplorerChrome"]),
        .library(name: "FileExplorerViews", targets: ["FileExplorerViews"]),
        .library(name: "FileExplorerInspector", targets: ["FileExplorerInspector"]),
        .executable(name: "FileExplorerApp", targets: ["FileExplorerApp"])
    ],
    targets: [
        .target(
            name: "FileExplorerCore",
            dependencies: []
        ),
        .target(
            name: "FileExplorerDesign",
            dependencies: ["FileExplorerCore"]
        ),
        .target(
            name: "FileExplorerChrome",
            dependencies: ["FileExplorerCore", "FileExplorerDesign"]
        ),
        .target(
            name: "FileExplorerViews",
            dependencies: ["FileExplorerCore", "FileExplorerDesign"]
        ),
        .target(
            name: "FileExplorerInspector",
            dependencies: ["FileExplorerCore", "FileExplorerDesign"]
        ),
        .executableTarget(
            name: "FileExplorerApp",
            dependencies: [
                "FileExplorerCore",
                "FileExplorerDesign",
                "FileExplorerChrome",
                "FileExplorerViews",
                "FileExplorerInspector"
            ]
        ),
        .testTarget(
            name: "FileExplorerCoreTests",
            dependencies: ["FileExplorerCore"]
        )
    ]
)

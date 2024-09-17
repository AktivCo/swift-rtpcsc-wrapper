// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription


let package = Package(
    name: "rt-pcsc-wrapper",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "RtPcscWrapper",
            targets: ["RtPcscWrapper"])
    ],
    dependencies: [
        .package(url: "git@scm.aktivco.ru:rutoken/dev/ios-projects/swift-packages/rt-pcsc.git",
                 revision: "d6ee84c7c1101a5be27d3efe4fe1a644da2baff9"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins",
                 from: "0.56.1")
    ],
    targets: [
        .target(
            name: "RtPcscWrapper",
            dependencies: [
                .product(name: "RtPcsc",
                         package: "rt-pcsc")
            ],
            plugins: [
                 .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")
             ]
        )
    ]
)

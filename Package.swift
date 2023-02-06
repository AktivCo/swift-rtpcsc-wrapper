// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "rt-pcsc-wrapper",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "PcscWrapper",
            targets: ["PcscWrapper"]),
    ],
    dependencies: [
        .package(url: "git@scm.aktivco.ru:rutoken/dev/ios-projects/swift-packages/rt-pcsc.git",
                         revision: "663b57fbcb6e789d17431897ef6b8d610e48b0ac")
    ],
    targets: [
        .target(
            name: "PcscWrapper",
            dependencies: [
                .product(name: "RtPcsc",
                         package: "rt-pcsc")
            ]
        ),
    ]
)

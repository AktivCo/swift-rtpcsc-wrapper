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
            name: "RtPcscWrapper",
            targets: ["RtPcscWrapper"])
    ],
    dependencies: [
        .package(url: "git@scm.aktivco.ru:rutoken/dev/ios-projects/swift-packages/rt-pcsc.git",
                 revision: "714751edf062a8d775a878743e89bdcfd438fdf6")

    ],
    targets: [
        .target(
            name: "RtPcscWrapper",
            dependencies: [
                .product(name: "RtPcsc",
                         package: "rt-pcsc")
            ]
        )
    ]
)

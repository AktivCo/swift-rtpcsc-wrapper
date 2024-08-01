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
        .package(url: "https://github.com/AktivCo/swift-rtpcsc-binary.git", exact: .init(stringLiteral: "5.3.0"))
    ],
    targets: [
        .target(
            name: "RtPcscWrapper",
            dependencies: [
                .product(name: "RtPcsc",
                         package: "swift-rtpcsc-binary")
            ]
        )
    ]
)

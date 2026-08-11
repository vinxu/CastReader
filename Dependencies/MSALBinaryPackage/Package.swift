// swift-tools-version: 5.9

import PackageDescription

/// Thin, reproducible wrapper around Microsoft's official MSAL 2.14.1 binary.
/// The checked-in XCFramework is byte-for-byte extracted from the upstream
/// release recorded in ORIGIN.md, avoiding network/keychain stalls in Xcode's
/// binary-artifact downloader and a clone of MSAL's very large Git history.
let package = Package(
    name: "MSALBinaryPackage",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(name: "MSAL", targets: ["MSAL"]),
    ],
    targets: [
        .binaryTarget(
            name: "MSAL",
            path: "MSAL.xcframework"
        ),
    ]
)

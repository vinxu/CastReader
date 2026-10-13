// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ParserProbe",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "/Users/xuxuheng/Library/Developer/Xcode/DerivedData/CastReader-bnmsjegjmgyyfmesawfpybugtzsg/SourcePackages/checkouts/SwiftSoup")],
    targets: [.executableTarget(name: "ParserProbe", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")])]
)

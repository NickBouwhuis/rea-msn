// swift-tools-version: 5.10
import PackageDescription

// One package, two front ends over the shared MSNKit protocol library:
// a SwiftUI/AppKit app on macOS and a GTK4 app on Linux.
var targets: [Target] = [
	// zlib, for MSZIP-compressed wink cabinets (MSNKit/Util/Cabinet.swift).
	.systemLibrary(name: "CZlib", providers: [.apt(["zlib1g-dev"])]),
	.executableTarget(name: "msnctl", dependencies: ["MSNKit"]),
	.testTarget(name: "MSNKitTests", dependencies: ["MSNKit"]),
]
var products: [Product] = [
	.library(name: "MSNKit", targets: ["MSNKit"]),
	.executable(name: "msnctl", targets: ["msnctl"]),
]
var dependencies: [Package.Dependency] = []

#if os(Linux)
dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
targets += [
	.target(name: "MSNKit", dependencies: ["CZlib", .product(name: "Crypto", package: "swift-crypto")]),
	.systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
	.executableTarget(name: "MessengerGTK", dependencies: ["MSNKit", "CGtk"]),
]
products.append(.executable(name: "MessengerGTK", targets: ["MessengerGTK"]))
#else
targets += [
	.target(name: "MSNKit", dependencies: ["CZlib"]),
	.executableTarget(name: "Messenger", dependencies: ["MSNKit"]),
]
products.append(.executable(name: "Messenger", targets: ["Messenger"]))
#endif

let package = Package(
	name: "Messenger",
	platforms: [.macOS(.v14)],
	products: products,
	dependencies: dependencies,
	targets: targets
)

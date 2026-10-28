// swift-tools-version: 5.10
import PackageDescription

// One package, two front ends over the shared MSNKit protocol library:
// a SwiftUI/AppKit app on macOS and a GTK4 app on Linux. MatrixKit puts the
// same client surface (MSNKit's IMService) over Matrix: on macOS through
// matrix-rust-sdk (end-to-end encryption, verification), on Linux for now
// over the plain client-server API.
var targets: [Target] = [
	.executableTarget(name: "msnctl", dependencies: ["MSNKit", "MatrixKit"]),
	.testTarget(name: "MSNKitTests", dependencies: ["MSNKit"]),
	.testTarget(name: "MatrixKitTests", dependencies: ["MatrixKit", "MSNKit"]),
]
var products: [Product] = [
	.library(name: "MSNKit", targets: ["MSNKit"]),
	.library(name: "MatrixKit", targets: ["MatrixKit"]),
	.executable(name: "msnctl", targets: ["msnctl"]),
]
var dependencies: [Package.Dependency] = []

#if os(Linux)
dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
targets += [
	.target(name: "MSNKit", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
	.target(name: "MatrixKit", dependencies: ["MSNKit"]),
	.systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
	.executableTarget(name: "MessengerGTK", dependencies: ["MSNKit", "MatrixKit", "CGtk"]),
]
products.append(.executable(name: "MessengerGTK", targets: ["MessengerGTK"]))
#else
dependencies.append(.package(url: "https://github.com/matrix-org/matrix-rust-components-swift", exact: "26.10.27"))
targets += [
	.target(name: "MSNKit"),
	.target(name: "MatrixKit", dependencies: ["MSNKit", .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift")]),
	.executableTarget(name: "Messenger", dependencies: ["MSNKit", "MatrixKit"]),
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

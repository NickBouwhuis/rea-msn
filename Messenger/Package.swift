// swift-tools-version: 5.10
import Foundation
import PackageDescription

// Two apps, each for macOS (SwiftUI/AppKit) and Linux (GTK4), from one set of
// windows (MessengerUI, MessengerGTKUI) over MSNKit's IMService:
// - Messenger: Escargot (MSNP15, MSNKit)
// - Messenger for Matrix (MatrixMessenger*): MatrixKit, through matrix-rust-sdk
//   (end-to-end encryption, verification): a release of its Swift package on
//   macOS, and on Linux a build of the same commit that
//   linux/scripts/build-matrix-sdk.sh puts in Vendor/MatrixSDK. A Linux build
//   without that folder is the plain client-server client, unencrypted.
var targets: [Target] = [
	// zlib, for MSZIP-compressed wink cabinets (MSNKit/Util/Cabinet.swift).
	.systemLibrary(name: "CZlib", providers: [.apt(["zlib1g-dev"])]),
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
	.target(name: "MSNKit", dependencies: ["CZlib", .product(name: "Crypto", package: "swift-crypto")]),
]
let sdk = Context.packageDirectory + "/Vendor/MatrixSDK"
if FileManager.default.fileExists(atPath: sdk + "/lib/libmatrix_sdk_ffi.a") {
	targets += [
		.systemLibrary(name: "MatrixSDKFFI", path: "Vendor/MatrixSDK/include"),
		.target(name: "MatrixRustSDK", dependencies: ["MatrixSDKFFI"], path: "Vendor/MatrixSDK/swift",
		        swiftSettings: [.unsafeFlags(["-suppress-warnings"])],
		        linkerSettings: [.unsafeFlags(["-L\(sdk)/lib"]), .linkedLibrary("matrix_sdk_ffi"),
		                         .linkedLibrary("m"), .linkedLibrary("dl"), .linkedLibrary("pthread")]),
		.target(name: "MatrixKit", dependencies: ["MSNKit", "MatrixRustSDK"]),
	]
} else {
	targets.append(.target(name: "MatrixKit", dependencies: ["MSNKit"]))
}
targets += [
	.systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
	.target(name: "MessengerGTKUI", dependencies: ["MSNKit", "CGtk"]),
	.executableTarget(name: "MessengerGTK", dependencies: ["MessengerGTKUI", "MSNKit"]),
	.executableTarget(name: "MatrixMessengerGTK", dependencies: ["MessengerGTKUI", "MatrixKit"]),
]
products += [
	.executable(name: "MessengerGTK", targets: ["MessengerGTK"]),
	.executable(name: "MatrixMessengerGTK", targets: ["MatrixMessengerGTK"]),
]
#else
dependencies.append(.package(url: "https://github.com/matrix-org/matrix-rust-components-swift", exact: "26.10.27"))
targets += [
	.target(name: "MSNKit", dependencies: ["CZlib"]),
	.target(name: "MatrixKit", dependencies: ["MSNKit", .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift")]),
	.target(name: "MessengerUI", dependencies: ["MSNKit"]),
	.executableTarget(name: "Messenger", dependencies: ["MessengerUI", "MSNKit"]),
	.executableTarget(name: "MatrixMessenger", dependencies: ["MessengerUI", "MatrixKit"]),
]
products += [
	.executable(name: "Messenger", targets: ["Messenger"]),
	.executable(name: "MatrixMessenger", targets: ["MatrixMessenger"]),
]
#endif

let package = Package(
	name: "Messenger",
	platforms: [.macOS(.v14)],
	products: products,
	dependencies: dependencies,
	targets: targets
)

// swift-tools-version: 5.8

import PackageDescription

let package = Package(
	name: "Neon",
	platforms: [.macOS(.v10_13), .iOS(.v11), .tvOS(.v11), .watchOS(.v5)],
	products: [
		.library(name: "Neon", targets: ["Neon"]),
	],
	dependencies: [
		.package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.8.0"),
		.package(url: "https://github.com/ChimeHQ/Rearrange", from: "1.6.0"),
	],
	targets: [
		.target(
			name: "Neon",
			dependencies: ["SwiftTreeSitter", "Rearrange", "TreeSitterClient"],
			swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
		),
		.target(name: "TreeSitterClient", dependencies: ["Rearrange", "SwiftTreeSitter"]),
		.testTarget(name: "NeonTests", dependencies: ["Neon"])
	]
)

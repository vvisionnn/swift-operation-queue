// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "swift-operation-queue",
	platforms: [
		.macOS(.v10_15),
		.iOS(.v13),
		.tvOS(.v13),
		.watchOS(.v6),
		.macCatalyst(.v13),
		.visionOS(.v1),
	],
	products: [
		.library(name: "OperationQueue", targets: ["OperationQueue"]),
	],
	dependencies: [
		.package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.7.0"),
		.package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
		.package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.0.0"),
	],
	targets: [
		.target(
			name: "OperationQueue",
			dependencies: [
				.product(name: "Tagged", package: "swift-tagged"),
				.product(name: "OrderedCollections", package: "swift-collections"),
				.product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
			]
		),
		.testTarget(
			name: "OperationQueueTests",
			dependencies: ["OperationQueue"]
		),
	]
)

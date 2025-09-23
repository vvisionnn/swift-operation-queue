// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "swift-operation-queue",
	platforms: [
		.macOS(.v13),
		.iOS(.v16),
		.tvOS(.v16),
		.watchOS(.v9),
		.macCatalyst(.v16),
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

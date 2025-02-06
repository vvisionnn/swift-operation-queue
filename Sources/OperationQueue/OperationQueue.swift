import Foundation

public protocol OperationQueue: Sendable {
	typealias Action = @Sendable () async -> Void
	associatedtype TaskIdentifier: Identifiable & Hashable & Sendable

	func enqueue(_ identifiable: TaskIdentifier, operation: @escaping Action)
	func cancel(_ identifiable: TaskIdentifier)
	func cancel(_ identifiables: [TaskIdentifier])
	func cancelAll()
}

public typealias AsyncOperationQueue = OperationQueue

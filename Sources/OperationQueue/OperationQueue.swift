import Foundation

public protocol OperationQueue: Sendable {
	typealias Action = @Sendable () async -> Void
	typealias CancelAction = @Sendable () -> Void
	associatedtype TaskIdentifier: Identifiable & Hashable & Sendable

	func enqueue(_ identifiable: TaskIdentifier, operation: @escaping Action, onCancel: CancelAction?)
	func cancel(_ identifiable: TaskIdentifier)
	func cancel(_ identifiables: [TaskIdentifier])
	func cancelAll()
}

public typealias AsyncOperationQueue = OperationQueue

extension OperationQueue {
	public func enqueue(_ identifiable: TaskIdentifier, operation: @escaping Action, onCancel: CancelAction? = nil) {
		enqueue(identifiable, operation: operation, onCancel: onCancel)
	}
}

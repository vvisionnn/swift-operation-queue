import ConcurrencyExtras
import Foundation
import OrderedCollections
import Tagged

public final class ConcurrentOperationQueue<TaskIdentifier: Identifiable & Hashable & Sendable>: AsyncOperationQueue {
	private let dispatchQueue = DispatchQueue(label: "operation-queue-\(UUID().uuidString)")
	private let operations: LockIsolated<OrderedDictionary<Element.Identifier, Context>> = .init(.init())
	private let maxConcurrentOperationCount: LockIsolated<Int>

	deinit {
		self.operations.values.forEach { $0.cancel() }
		self.operations.withValue { $0.removeAll() }
	}

	public init(maxConcurrentOperationCount: Int = 1) {
		self.maxConcurrentOperationCount = .init(maxConcurrentOperationCount)
	}

	public func enqueue(
		_ identifiable: TaskIdentifier,
		operation: @escaping Action,
		onCancel: CancelAction? = nil
	) {
		dispatchQueue.async {
			defer { self.check() }

			// check and return if operation already exists
			let identifider = Element.Identifier(identifiable)
			guard self.operations.value.notExists(identifider) else { return }

			// do real enqueue operation
			self.operations.withValue { operations in
				operations[identifider] = .init(
					element: .init(
						identifier: identifider,
						operation: .init(rawValue: { [weak self] in
							await operation()
							self?.check()
						}),
						onCancel: onCancel
					)
				)
			}
		}
	}

	public func cancel(_ identifiable: TaskIdentifier) {
		dispatchQueue.async {
			defer { self.check() }
			let identifier = Element.Identifier(identifiable)
			self.operations[identifier]?.cancel()
			_ = self.operations.withValue {
				$0.removeValue(forKey: identifier)
			}
		}
	}

	public func cancel(_ identifiables: [TaskIdentifier]) {
		dispatchQueue.async {
			defer { self.check() }
			identifiables
				.map(Element.Identifier.init(rawValue:))
				.forEach { key in
					self.operations[key]?.cancel()
					_ = self.operations.withValue { $0.removeValue(forKey: key) }
				}
		}
	}

	public func cancelAll() {
		dispatchQueue.async {
			defer { self.check() }
			self.operations.values.forEach { $0.cancel() }
			self.operations.withValue { $0.removeAll() }
		}
	}

	private func check() {
		// do async operation for check or may leads some deadlock problem
		dispatchQueue.async {
			self.operations.withValue {
				$0.removeAll(where: \.value.state.isFinished)
			}

			let runningCount = self.operations.value.filter(\.value.state.isRunning).count
			guard runningCount < self.maxConcurrentOperationCount.value else { return }

			// start the rest operations
			let restCount = max(0, self.maxConcurrentOperationCount.value - runningCount)
			self.operations.value.filter(\.value.state.isNotStarted)
				.prefix(restCount)
				.map(\.value)
				.forEach { $0.start { [weak self] in self?.check() } }

			#if DEBUG
			assert(
				self.operations.value.filter(\.value.state.isRunning).count
					<= self.maxConcurrentOperationCount.value
			)
			#endif
		}
	}
}

// Public access, all should be wrap in sync operation
// and shouldn't be used in any internal/private operation
extension ConcurrentOperationQueue {
	public var maxConcurrentCount: Int {
		get { dispatchQueue.sync { self.maxConcurrentOperationCount.value } }
		set { dispatchQueue.sync { self.maxConcurrentOperationCount.setValue(newValue) } }
	}

	public var totalCount: Int {
		dispatchQueue.sync {
			self.operations.count
		}
	}

	public var runningCount: Int {
		dispatchQueue.sync {
			self.operations.value
				.filter(\.value.state.isRunning)
				.count
		}
	}

	public var isValidRunningCount: Bool {
		dispatchQueue.sync {
			let runningCount = self.operations.value.filter(\.value.state.isRunning).count
			let maxConcurrentOperationCount = self.maxConcurrentOperationCount.value
			assert(runningCount <= maxConcurrentOperationCount)
			return runningCount <= maxConcurrentOperationCount
		}
	}
}

extension ConcurrentOperationQueue {
	public enum Error: Swift.Error {
		case operationAlreadyExists
	}
}

extension ConcurrentOperationQueue {
	final class Context: Sendable {
		let element: Element
		let state: LockIsolated<State> = .init(.notStarted)
		let task: LockIsolated<Task<Void, Never>?>

		deinit { self.cancel() }

		init(element: Element) {
			self.element = element
			self.task = .init(nil)
		}

		func start(_ completion: @escaping @Sendable () async -> Void) {
			guard state.value == .notStarted else { return }
			state.withValue { $0 = .running }
			task.value?.cancel()
			task.withValue {
				$0 = .init(operation: { [weak self] in
					await self?.element.operation.rawValue()
					self?.state.withValue { $0 = .finished }
					await completion()
				})
			}
		}

		func cancel() {
			guard state.value != .finished else { return }
			defer { state.withValue { $0 = .finished } }
			task.value?.cancel()
			element.onCancel?()
		}
	}

	final class Element: Identifiable, Sendable {
		let id: Identifier
		let operation: Operation
		let onCancel: (@Sendable () -> Void)?

		init(
			identifier: Identifier,
			operation: Operation,
			onCancel: (@Sendable () -> Void)? = nil
		) {
			self.id = identifier
			self.operation = operation
			self.onCancel = onCancel
		}
	}
}

extension ConcurrentOperationQueue.Element {
	typealias Identifier = Tagged<ConcurrentOperationQueue<TaskIdentifier>, TaskIdentifier>
	typealias Operation = Tagged<ConcurrentOperationQueue<TaskIdentifier>, ConcurrentOperationQueue.Action>
}

extension ConcurrentOperationQueue.Context {
	enum State: UInt, CaseIterable {
		case notStarted
		case running
		case finished

		var isNotStarted: Bool { self == .notStarted }
		var isRunning: Bool { self == .running }
		var isFinished: Bool { self == .finished }
	}
}

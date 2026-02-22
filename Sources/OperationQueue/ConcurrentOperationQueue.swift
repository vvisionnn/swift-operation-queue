import ConcurrencyExtras
import OrderedCollections
import Tagged

public final class ConcurrentOperationQueue<TaskIdentifier: Identifiable & Hashable & Sendable>: AsyncOperationQueue {
	private let operations: LockIsolated<OrderedDictionary<Element.Identifier, Context>> = .init(.init())
	private let maxConcurrentOperationCount: LockIsolated<Int>

	deinit {
		let contexts = self.operations.withValue { ops -> [Context] in
			let all = Array(ops.values)
			ops.removeAll()
			return all
		}
		contexts.forEach { $0.cancel() }
	}

	public init(maxConcurrentOperationCount: Int = 1) {
		self.maxConcurrentOperationCount = .init(maxConcurrentOperationCount)
	}

	public func enqueue(
		_ identifiable: TaskIdentifier,
		operation: @escaping Action,
		onCancel: CancelAction? = nil
	) {
		let identifier = Element.Identifier(identifiable)

		let inserted = self.operations.withValue { operations -> Bool in
			guard operations.notExists(identifier) else { return false }
			operations[identifier] = .init(
				element: .init(
					identifier: identifier,
					operation: .init(rawValue: { [weak self] in
						await operation()
						self?.check()
					}),
					onCancel: onCancel
				)
			)
			return true
		}

		if inserted {
			check()
		}
	}

	public func cancel(_ identifiable: TaskIdentifier) {
		let identifier = Element.Identifier(identifiable)
		let context = self.operations.withValue { $0.removeValue(forKey: identifier) }
		context?.cancel()
		check()
	}

	public func cancel(_ identifiables: [TaskIdentifier]) {
		let contexts = self.operations.withValue { ops in
			identifiables
				.map(Element.Identifier.init(rawValue:))
				.compactMap { ops.removeValue(forKey: $0) }
		}
		contexts.forEach { $0.cancel() }
		check()
	}

	public func cancelAll() {
		let contexts = self.operations.withValue { ops -> [Context] in
			let all = Array(ops.values)
			ops.removeAll()
			return all
		}
		contexts.forEach { $0.cancel() }
	}

	private func check() {
		let maxCount = self.maxConcurrentOperationCount.value

		let toStart = self.operations.withValue { ops -> [Context] in
			ops.removeAll(where: \.value.state.isFinished)

			let runningCount = ops.filter(\.value.state.isRunning).count
			guard runningCount < maxCount else { return [] }

			let slots = max(0, maxCount - runningCount)
			let result = Array(
				ops.filter(\.value.state.isNotStarted)
					.prefix(slots)
					.map(\.value)
			)

			#if DEBUG
			assert(runningCount + result.count <= maxCount)
			#endif

			return result
		}

		toStart.forEach { $0.start { [weak self] in self?.check() } }
	}
}

extension ConcurrentOperationQueue {
	public var maxConcurrentCount: Int {
		get { self.maxConcurrentOperationCount.value }
		set { self.maxConcurrentOperationCount.setValue(newValue) }
	}

	public var totalCount: Int {
		self.operations.count
	}

	public var runningCount: Int {
		self.operations.value.filter(\.value.state.isRunning).count
	}

	public var isValidRunningCount: Bool {
		let runningCount = self.operations.value.filter(\.value.state.isRunning).count
		let maxConcurrentOperationCount = self.maxConcurrentOperationCount.value
		assert(runningCount <= maxConcurrentOperationCount)
		return runningCount <= maxConcurrentOperationCount
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

		struct Runtime: Sendable {
			var state: State = .notStarted
			var task: Task<Void, Never>?
		}

		private let runtime: LockIsolated<Runtime> = .init(.init())

		/// Computed accessor for key-path compatibility (e.g. `\.value.state.isRunning`).
		var state: State { runtime.value.state }

		deinit { self.cancel() }

		init(element: Element) {
			self.element = element
		}

		func start(_ completion: @escaping @Sendable () async -> Void) {
			runtime.withValue { rt in
				guard rt.state == .notStarted else { return }
				rt.state = .running
				rt.task = .init(operation: { [weak self] in
					await self?.element.operation.rawValue()
					self?.runtime.withValue { $0.state = .finished }
					await completion()
				})
			}
		}

		func cancel() {
			let shouldCancel = runtime.withValue { rt -> Bool in
				guard rt.state != .finished else { return false }
				rt.state = .finished
				rt.task?.cancel()
				return true
			}
			guard shouldCancel else { return }
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

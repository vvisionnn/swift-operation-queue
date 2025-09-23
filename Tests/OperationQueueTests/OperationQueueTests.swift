import ConcurrencyExtras
import Foundation
@testable import OperationQueue
import Testing

// MARK: - Test Tags

extension Tag {
	@Tag static var concurrency: Self
	@Tag static var cancellation: Self
	@Tag static var lifecycle: Self
	@Tag static var performance: Self
}

// MARK: - Test Suite

@Suite("ConcurrentOperationQueue Tests", .tags(.concurrency))
struct OperationQueueTests {
	// MARK: - Initialization & Configuration Tests

	@Test("Queue initializes with default configuration")
	func initialization() {
		_ = ConcurrentOperationQueue<TestContextObject>()
	}

	@Test("Default max concurrent operation count is 1")
	func defaultMaxConcurrentOperationCount() {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		#expect(queue.maxConcurrentCount == 1)
	}

	@Test("Max concurrent operation count can be updated")
	func updateMaxConcurrentOperationCount() {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		let newCount = 5
		queue.maxConcurrentCount = newCount
		#expect(queue.maxConcurrentCount == newCount)
	}

	@Test("Public properties are accessible")
	func publicAccess() {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		_ = queue.runningCount
		_ = queue.maxConcurrentCount
		_ = queue.totalCount
	}

	// MARK: - Concurrency Control Tests

	@Test(
		"Queue respects max concurrent operation limit",
		.tags(.performance),
		.timeLimit(.minutes(1))
	)
	func maxConcurrentOperationCount() async throws {
		let maxCount = 100
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: maxCount)

		for _ in 0 ..< 2000 {
			queue.enqueue(.init(id: UUID())) { [weak queue] in
				guard let queue = queue else { return }
				#expect(queue.isValidRunningCount)
			}
			#expect(queue.isValidRunningCount)
		}

		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}
		#expect(queue.totalCount == 0)
	}

	@Test(
		"Concurrent count can be updated during execution",
		.tags(.performance),
		.timeLimit(.minutes(1))
	)
	func updateConcurrentNumberWhenRunning() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 3)
		let allOperationCount = 200

		try await confirmation(expectedCount: allOperationCount) { confirmation in
			for taskNumber in 0 ..< allOperationCount {
				queue.enqueue(.init(id: UUID())) { [weak queue, taskNumber] in
					guard let queue = queue else { return }
					#expect(queue.isValidRunningCount)
					if queue.isValidRunningCount {
						confirmation()
					}

					if taskNumber % 10 == 0 {
						queue.maxConcurrentCount += 1
					}
				}
			}

			while queue.totalCount > 0 {
				try await Task.sleep(nanoseconds: 10_000)
			}
		}
	}

	// MARK: - Cancellation Tests

	@Test(
		"Individual task cancellation works correctly",
		.tags(.cancellation)
	)
	func cancelWhenEnqueue() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		let context = TestContextObject(id: UUID())

		await confirmation(expectedCount: 0) { confirmation in
			queue.enqueue(context) {
				try? await Task.sleep(nanoseconds: 500_000_000)
				#expect(Task.isCancelled)
				confirmation()
			}

			queue.cancel(context)
		}
	}

	@Test(
		"Multiple task cancellation works correctly",
		.tags(.cancellation)
	)
	func cancelMultipleContextObjects() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 3)
		let context1 = TestContextObject(id: UUID())
		let context2 = TestContextObject(id: UUID())
		let context3 = TestContextObject(id: UUID())

		try await confirmation("all cancelled no confirmation called", expectedCount: 0) { confirmation in
			queue.enqueue(context1) {
				try? await Task.sleep(nanoseconds: 1_000_000)
				if !Task.isCancelled {
					confirmation()
				}
				#expect(Task.isCancelled)
			}

			queue.enqueue(context2) {
				try? await Task.sleep(nanoseconds: 1_000_000)
				if !Task.isCancelled {
					confirmation()
				}
				#expect(Task.isCancelled)
			}

			queue.enqueue(context3) {
				try? await Task.sleep(nanoseconds: 1_000_000)
				if !Task.isCancelled {
					confirmation()
				}
				#expect(Task.isCancelled)
			}

			queue.cancel([context1, context2, context3])

			while queue.totalCount > 0 {
				try await Task.sleep(nanoseconds: 10_000)
			}
		}
	}

	@Test(
		"Cancel all tasks removes all pending operations",
		.tags(.cancellation)
	)
	func cancelAll() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 10)
		let allOperationCount = 10

		await confirmation("all cancelled, no confirmation called", expectedCount: 0) { confirmation in
			(0 ..< allOperationCount).forEach { _ in
				queue.enqueue(.init(id: UUID())) {
					try? await Task.sleep(nanoseconds: 100_000_000)
					#expect(Task.isCancelled)
					if !Task.isCancelled {
						confirmation()
					}
				}
			}
			queue.cancelAll()
			#expect(queue.totalCount == 0)
		}
	}

	// MARK: - onCancel Callback Tests

	@Test(
		"onCancel callback is invoked when running task is cancelled",
		.tags(.cancellation)
	)
	func onCancelCalledForRunningTask() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 1)
		let context = TestContextObject(id: UUID())
		let cancelTracker = LockIsolated<Bool>(false)

		await withCheckedContinuation { taskStarted in
			queue.enqueue(context, operation: {
				taskStarted.resume()
				try? await Task.sleep(nanoseconds: 1_000_000_000) // Long-running task
			}, onCancel: {
				cancelTracker.setValue(true)
			})
		}

		// Cancel the running task
		queue.cancel(context)

		// Wait for queue to be empty (cancel completed)
		while queue.totalCount > 0 {
			try? await Task.sleep(nanoseconds: 1_000)
		}

		#expect(cancelTracker.value == true)
	}

	@Test(
		"onCancel callback is invoked when queued task is cancelled",
		.tags(.cancellation)
	)
	func onCancelCalledForQueuedTask() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 1)
		let runningContext = TestContextObject(id: UUID())
		let queuedContext = TestContextObject(id: UUID())
		let cancelTracker = LockIsolated<Bool>(false)

		// First, fill the queue with a long-running task and wait for it to start
		await withCheckedContinuation { firstTaskStarted in
			queue.enqueue(runningContext, operation: {
				firstTaskStarted.resume()
				try? await Task.sleep(nanoseconds: 2_000_000_000) // Very long task
			})
		}

		// Then enqueue a second task that will be queued (not started immediately)
		queue.enqueue(queuedContext, operation: {
			// This should never run because we'll cancel it
		}, onCancel: {
			cancelTracker.setValue(true)
		})

		// Cancel the queued task before it starts
		queue.cancel(queuedContext)

		// Wait for cancellation to complete
		while queue.totalCount > 1 { // Should have 1 running task left
			try? await Task.sleep(nanoseconds: 1_000)
		}

		#expect(cancelTracker.value == true)

		// Cleanup the running task
		queue.cancel(runningContext)
		while queue.totalCount > 0 {
			try? await Task.sleep(nanoseconds: 1_000)
		}
	}

	@Test(
		"onCancel callback is NOT invoked when task completes normally",
		.tags(.cancellation, .lifecycle)
	)
	func onCancelNotCalledForCompletedTask() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		let context = TestContextObject(id: UUID())
		let cancelTracker = LockIsolated<Bool>(false)

		await withCheckedContinuation { taskCompleted in
			queue.enqueue(context, operation: {
				taskCompleted.resume()
			}, onCancel: {
				cancelTracker.setValue(true)
			})
		}

		// Wait for queue to be empty
		while queue.totalCount > 0 {
			try? await Task.sleep(nanoseconds: 1_000)
		}

		#expect(cancelTracker.value == false) // onCancel should NOT be called for completed tasks
	}

	@Test(
		"onCancel callbacks are invoked during cancelAll operation",
		.tags(.cancellation)
	)
	func onCancelCalledDuringCancelAll() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 2)
		let context1 = TestContextObject(id: UUID())
		let context2 = TestContextObject(id: UUID())
		let cancelCallCounter = LockIsolated<Int>(0)

		// Wait for both tasks to start using continuation
		await withCheckedContinuation { bothTasksStarted in
			let startCounter = LockIsolated<Int>(0)

			queue.enqueue(context1, operation: {
				let count = startCounter.withValue { $0 += 1; return $0 }
				if count == 2 { bothTasksStarted.resume() }
				try? await Task.sleep(nanoseconds: 1_000_000_000) // Long task
			}, onCancel: {
				cancelCallCounter.withValue { $0 += 1 }
			})

			queue.enqueue(context2, operation: {
				let count = startCounter.withValue { $0 += 1; return $0 }
				if count == 2 { bothTasksStarted.resume() }
				try? await Task.sleep(nanoseconds: 1_000_000_000) // Long task
			}, onCancel: {
				cancelCallCounter.withValue { $0 += 1 }
			})
		}

		// Cancel all tasks
		queue.cancelAll()

		// Wait for queue to be empty
		while queue.totalCount > 0 {
			try? await Task.sleep(nanoseconds: 1_000)
		}

		#expect(cancelCallCounter.value == 2)
	}

	// MARK: - Lifecycle Tests

	@Test(
		"Queue properly handles deinitialization cancellation",
		.tags(.lifecycle, .cancellation)
	)
	func deinitCancelAll() async throws {
		var queue = ConcurrentOperationQueue<TestContextObject>()
		let context = TestContextObject(id: UUID())

		try await confirmation("cancelled when deinit", expectedCount: 0) { confirmation in
			queue.enqueue(context) {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
				#expect(Task.isCancelled)
				confirmation()
			}
			#expect(queue.totalCount == 1)
			queue = ConcurrentOperationQueue()
			while queue.totalCount > 0 {
				try await Task.sleep(nanoseconds: 10_000)
			}
		}
	}
}

// MARK: - Test Support Types

extension OperationQueueTests {
	struct TestContextObject: Identifiable, Hashable, Sendable {
		let id: UUID
	}
}

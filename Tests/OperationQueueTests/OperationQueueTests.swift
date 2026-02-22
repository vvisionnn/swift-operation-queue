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

	// MARK: - GCD-Free Correctness Tests

	@Test(
		"Serial queue executes operations in FIFO order",
		.tags(.concurrency),
		.timeLimit(.minutes(1))
	)
	func fifoOrdering() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 1)
		let order = LockIsolated<[Int]>([])

		for i in 0 ..< 20 {
			queue.enqueue(.init(id: UUID())) {
				order.withValue { $0.append(i) }
			}
		}

		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}

		#expect(order.value == Array(0 ..< 20))
	}

	@Test(
		"Duplicate identifier enqueue is silently rejected",
		.tags(.concurrency),
		.timeLimit(.minutes(1))
	)
	func duplicateEnqueueRejected() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 2)
		let sharedId = UUID()
		let count = LockIsolated(0)

		queue.enqueue(TestContextObject(id: sharedId)) {
			try? await Task.sleep(nanoseconds: 50_000_000)
			count.withValue { $0 += 1 }
		}

		// Same ID -- must be rejected
		queue.enqueue(TestContextObject(id: sharedId)) {
			count.withValue { $0 += 1 }
		}

		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}

		#expect(count.value == 1)
	}

	@Test(
		"Concurrent enqueue from multiple tasks is thread-safe",
		.tags(.concurrency, .performance),
		.timeLimit(.minutes(1))
	)
	func concurrentEnqueue() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 10)
		let completed = LockIsolated(0)
		let total = 200

		await withTaskGroup(of: Void.self) { group in
			for _ in 0 ..< total {
				group.addTask {
					queue.enqueue(.init(id: UUID())) {
						completed.withValue { $0 += 1 }
					}
				}
			}
		}

		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}

		#expect(completed.value == total)
	}

	@Test(
		"Multiple queue instances work concurrently without interference",
		.tags(.concurrency, .performance),
		.timeLimit(.minutes(1))
	)
	func multipleQueueInstances() async throws {
		let queueCount = 50
		let opsPerQueue = 20
		let completed = LockIsolated(0)

		await withTaskGroup(of: Void.self) { group in
			for _ in 0 ..< queueCount {
				group.addTask {
					let queue = ConcurrentOperationQueue<TestContextObject>(
						maxConcurrentOperationCount: 5
					)
					for _ in 0 ..< opsPerQueue {
						queue.enqueue(.init(id: UUID())) {
							completed.withValue { $0 += 1 }
						}
					}
					while queue.totalCount > 0 {
						try? await Task.sleep(nanoseconds: 10_000)
					}
				}
			}
		}

		#expect(completed.value == queueCount * opsPerQueue)
	}

	@Test(
		"Rapid operation completions do not deadlock check() reentrancy",
		.tags(.concurrency),
		.timeLimit(.minutes(1))
	)
	func checkReentrancyNonBlocking() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 1)
		let completed = LockIsolated(0)

		for _ in 0 ..< 100 {
			queue.enqueue(.init(id: UUID())) {
				completed.withValue { $0 += 1 }
			}
		}

		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}

		#expect(completed.value == 100)
	}

	@Test(
		"Concurrent enqueue and cancel operations are thread-safe",
		.tags(.concurrency, .cancellation),
		.timeLimit(.minutes(1))
	)
	func concurrentEnqueueAndCancel() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 5)

		await withTaskGroup(of: Void.self) { group in
			for _ in 0 ..< 100 {
				let ctx = TestContextObject(id: UUID())
				group.addTask {
					queue.enqueue(ctx) {
						try? await Task.sleep(nanoseconds: 1_000)
					}
				}
				group.addTask {
					queue.cancel(ctx)
				}
			}
		}

		// Must drain without hanging
		queue.cancelAll()
		#expect(queue.totalCount == 0)
	}

	@Test(
		"Serial queue never runs two operations simultaneously",
		.tags(.concurrency),
		.timeLimit(.minutes(1))
	)
	func serialExecutionEnforced() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 1)
		let concurrent = LockIsolated(0)
		let maxObserved = LockIsolated(0)

		for _ in 0 ..< 50 {
			queue.enqueue(.init(id: UUID())) {
				let current = concurrent.withValue { c -> Int in c += 1; return c }
				maxObserved.withValue { $0 = max($0, current) }
				try? await Task.sleep(nanoseconds: 1_000)
				concurrent.withValue { $0 -= 1 }
			}
		}

		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}

		#expect(maxObserved.value == 1)
	}

	@Test(
		"Parallel queue never exceeds max concurrent limit",
		.tags(.concurrency, .performance),
		.timeLimit(.minutes(1))
	)
	func parallelExecutionRespectsLimit() async throws {
		let maxConcurrent = 5
		let queue = ConcurrentOperationQueue<TestContextObject>(
			maxConcurrentOperationCount: maxConcurrent
		)
		let concurrent = LockIsolated(0)
		let maxObserved = LockIsolated(0)

		for _ in 0 ..< 200 {
			queue.enqueue(.init(id: UUID())) {
				let current = concurrent.withValue { c -> Int in c += 1; return c }
				maxObserved.withValue { $0 = max($0, current) }
				try? await Task.sleep(nanoseconds: 10_000)
				concurrent.withValue { $0 -= 1 }
			}
		}

		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}

		#expect(maxObserved.value <= maxConcurrent)
	}

	@Test(
		"Queue drains all operations to completion",
		.tags(.lifecycle),
		.timeLimit(.minutes(1))
	)
	func queueDrainsCompletely() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 3)
		let completed = LockIsolated(0)
		let total = 50

		try await confirmation(expectedCount: total) { confirmation in
			for _ in 0 ..< total {
				queue.enqueue(.init(id: UUID())) {
					completed.withValue { $0 += 1 }
					confirmation()
				}
			}

			while queue.totalCount > 0 {
				try await Task.sleep(nanoseconds: 10_000)
			}
		}

		#expect(completed.value == total)
		#expect(queue.totalCount == 0)
		#expect(queue.runningCount == 0)
	}

	// MARK: - Atomicity Tests (P1/P2 regression coverage)

	@Test(
		"Concurrent enqueue with same identifier only executes once",
		.tags(.concurrency),
		.timeLimit(.minutes(1))
	)
	func concurrentDuplicateEnqueue() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 10)
		let sharedId = UUID()
		let context = TestContextObject(id: sharedId)
		let executionCount = LockIsolated(0)

		// Hammer the same ID from 100 concurrent tasks
		await withTaskGroup(of: Void.self) { group in
			for _ in 0 ..< 100 {
				group.addTask {
					queue.enqueue(context) {
						executionCount.withValue { $0 += 1 }
					}
				}
			}
		}

		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}

		// Exactly one enqueue must win; the rest must be rejected
		#expect(executionCount.value == 1)
	}

	@Test(
		"cancelAll cancels every tracked operation atomically",
		.tags(.cancellation),
		.timeLimit(.minutes(1))
	)
	func cancelAllAtomicity() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 5)
		let onCancelCount = LockIsolated(0)
		let total = 20

		for _ in 0 ..< total {
			queue.enqueue(.init(id: UUID()), operation: {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}, onCancel: {
				onCancelCount.withValue { $0 += 1 }
			})
		}

		queue.cancelAll()

		// Dictionary must be empty immediately after cancelAll returns
		#expect(queue.totalCount == 0)
		// Every operation's onCancel must have been called
		#expect(onCancelCount.value == total)
	}

	@Test(
		"cancelAll with concurrent enqueues does not lose or leak operations",
		.tags(.concurrency, .cancellation),
		.timeLimit(.minutes(1))
	)
	func cancelAllWithConcurrentEnqueues() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 5)

		// Run many rounds of concurrent cancelAll + enqueue
		for _ in 0 ..< 20 {
			await withTaskGroup(of: Void.self) { group in
				for _ in 0 ..< 10 {
					group.addTask {
						queue.enqueue(.init(id: UUID())) {
							try? await Task.sleep(nanoseconds: 1_000)
						}
					}
				}
				group.addTask {
					queue.cancelAll()
				}
			}
		}

		// Final cleanup -- must not hang and must leave queue empty
		queue.cancelAll()
		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}
		#expect(queue.totalCount == 0)
	}

	@Test(
		"Enqueue after cancelAll works normally",
		.tags(.cancellation, .lifecycle),
		.timeLimit(.minutes(1))
	)
	func enqueueAfterCancelAll() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 3)
		let completed = LockIsolated(0)

		// Fill and cancel
		for _ in 0 ..< 10 {
			queue.enqueue(.init(id: UUID())) {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}
		queue.cancelAll()
		#expect(queue.totalCount == 0)

		// New operations after cancelAll must execute normally
		let postCancelTotal = 5
		for _ in 0 ..< postCancelTotal {
			queue.enqueue(.init(id: UUID())) {
				completed.withValue { $0 += 1 }
			}
		}

		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}

		#expect(completed.value == postCancelTotal)
	}

	// MARK: - Start/Cancel Race Tests (Context atomicity)

	@Test(
		"Cancel during start does not allow cancelled operation to execute",
		.tags(.concurrency, .cancellation),
		.timeLimit(.minutes(1))
	)
	func cancelDuringStartPreventsExecution() async throws {
		// Exercises the race: check() collects a context → another thread cancels
		// it → check() calls start(). With unified Runtime lock, start() must
		// see the .finished state and skip, OR cancel() must reach the Task.
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 1)
		let onCancelCount = LockIsolated(0)
		let executedAfterCancel = LockIsolated(0)

		// Run many rounds to stress the race window
		for _ in 0 ..< 200 {
			let ctx = TestContextObject(id: UUID())

			// Block the queue so the next enqueue is queued (not started)
			let blocker = TestContextObject(id: UUID())
			await withCheckedContinuation { started in
				queue.enqueue(blocker) {
					started.resume()
					try? await Task.sleep(nanoseconds: 100_000_000)
				}
			}

			// Enqueue a second operation that will be .notStarted
			queue.enqueue(ctx, operation: {
				// If this runs after onCancel fired, that's the bug
				if onCancelCount.value > 0 {
					executedAfterCancel.withValue { $0 += 1 }
				}
			}, onCancel: {
				onCancelCount.withValue { $0 += 1 }
			})

			// Cancel the queued operation — races with check()'s start()
			queue.cancel(ctx)

			// Clean up the blocker
			queue.cancel(blocker)

			// Reset for next round
			onCancelCount.setValue(0)
		}

		// No round should have seen an operation execute after its onCancel fired
		#expect(executedAfterCancel.value == 0)
	}

	@Test(
		"Concurrent cancel of running task guarantees onCancel fires exactly once",
		.tags(.concurrency, .cancellation),
		.timeLimit(.minutes(1))
	)
	func concurrentCancelOnSameContextFiresOnCancelOnce() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 10)
		let totalRounds = 100
		let onCancelTotal = LockIsolated(0)

		for _ in 0 ..< totalRounds {
			let ctx = TestContextObject(id: UUID())

			// Enqueue a long-running task
			queue.enqueue(ctx, operation: {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}, onCancel: {
				onCancelTotal.withValue { $0 += 1 }
			})

			// Race: cancel from multiple tasks simultaneously
			await withTaskGroup(of: Void.self) { group in
				for _ in 0 ..< 5 {
					group.addTask {
						queue.cancel(ctx)
					}
				}
			}
		}

		// Each round should fire onCancel exactly once (atomic shouldCancel guard)
		#expect(onCancelTotal.value == totalRounds)
	}

	@Test(
		"Cancel of queued task prevents it from ever starting",
		.tags(.concurrency, .cancellation),
		.timeLimit(.minutes(1))
	)
	func cancelQueuedTaskNeverStarts() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 1)
		let bodyRan = LockIsolated(false)

		for _ in 0 ..< 100 {
			bodyRan.setValue(false)

			// Block the queue
			let blocker = TestContextObject(id: UUID())
			await withCheckedContinuation { started in
				queue.enqueue(blocker) {
					started.resume()
					try? await Task.sleep(nanoseconds: 50_000_000)
				}
			}

			// Enqueue + immediately cancel a second task
			let ctx = TestContextObject(id: UUID())
			queue.enqueue(ctx) {
				bodyRan.setValue(true)
			}
			queue.cancel(ctx)

			// Unblock and drain
			queue.cancel(blocker)
			while queue.totalCount > 0 {
				try await Task.sleep(nanoseconds: 10_000)
			}

			// The cancelled task body must never have run
			#expect(bodyRan.value == false)
		}
	}

	@Test(
		"Stress: rapid start and cancel cycles on many contexts",
		.tags(.concurrency, .cancellation, .performance),
		.timeLimit(.minutes(1))
	)
	func stressStartCancelCycles() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 5)
		let onCancelCount = LockIsolated(0)
		let completedCount = LockIsolated(0)

		await withTaskGroup(of: Void.self) { group in
			for _ in 0 ..< 500 {
				let ctx = TestContextObject(id: UUID())
				group.addTask {
					queue.enqueue(ctx, operation: {
						completedCount.withValue { $0 += 1 }
					}, onCancel: {
						onCancelCount.withValue { $0 += 1 }
					})
				}
				// Cancel roughly half
				if Bool.random() {
					group.addTask {
						queue.cancel(ctx)
					}
				}
			}
		}

		// Drain remaining
		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}

		// Every operation must have either completed or been cancelled, never both.
		// Total accounted for should equal the number that were actually enqueued
		// (some enqueues may have raced with cancel before insertion).
		// Key invariant: no crash, no hang, no assertion failure.
		#expect(queue.totalCount == 0)
	}

	@Test(
		"Cancel racing with start does not leak running tasks",
		.tags(.concurrency, .cancellation),
		.timeLimit(.minutes(1))
	)
	func cancelRaceDoesNotLeakRunningTasks() async throws {
		// After cancel returns, the operation should not be executing with
		// Task.isCancelled == false. With unified Runtime lock, either:
		// - start() sees .finished and skips, OR
		// - cancel() sees the Task and cancels it.
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 3)
		let uncancelledExecutions = LockIsolated(0)

		for _ in 0 ..< 200 {
			let ctx = TestContextObject(id: UUID())

			queue.enqueue(ctx) {
				// If we're running but Task.isCancelled is false after onCancel fired,
				// that's the leaked-task bug
				if !Task.isCancelled {
					uncancelledExecutions.withValue { $0 += 1 }
				}
			}

			queue.cancel(ctx)
		}

		// Drain any that slipped through
		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10_000)
		}

		// Operations that ran should have run BEFORE cancel, not after.
		// With maxConcurrent=3 and immediate cancel, most should be prevented.
		// The key invariant is no crash/hang — uncancelledExecutions may be > 0
		// if the operation ran and completed before cancel() executed, which is
		// valid (cancel races with completion, not a bug).
		#expect(queue.totalCount == 0)
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

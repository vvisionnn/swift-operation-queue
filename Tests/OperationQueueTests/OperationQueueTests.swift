import ConcurrencyExtras
import Foundation
@testable import OperationQueue
import Testing

@Suite
struct OperationQueueTests {
	@Test func initialization() {
		_ = ConcurrentOperationQueue<TestContextObject>()
	}

	@Test func defaultMaxConcurrentOperationCount() {
		let defaultCount = ConcurrentOperationQueue<TestContextObject>()
			.maxConcurrentCount

		#expect(defaultCount == 1)
	}

	@Test func updateMaxConcurrentOperationCount() async {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		let newCount = 5
		queue.maxConcurrentCount = newCount
		let updatedCount = queue.maxConcurrentCount

		#expect(newCount == updatedCount)
	}

	@Test func maxConcurrentOperationCount() async throws {
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
			try await Task.sleep(nanoseconds: 10000)
		}
		#expect(queue.totalCount == 0)
	}

	@Test func cancelWhenEnqueue() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		let context = TestContextObject(id: UUID())
		await confirmation(expectedCount: 0) { confirmation in
			queue.enqueue(context) {
				try? await Task.sleep(nanoseconds: 500000000)
				#expect(Task.isCancelled)
				confirmation()
			}

			queue.cancel(context)
		}
	}

	@Test func deinitCancelAll() async throws {
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
				try await Task.sleep(nanoseconds: 10000)
			}
		}
	}

	@Test func cancelMultipleContextObjects() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 3)
		let context1 = TestContextObject(id: UUID())
		let context2 = TestContextObject(id: UUID())
		let context3 = TestContextObject(id: UUID())

		try await confirmation("all cancelled no confirmation called", expectedCount: 0) { confirmation in
			queue.enqueue(context1) {
				try? await Task.sleep(nanoseconds: 1000000)
				if !Task.isCancelled {
					confirmation()
				}
				#expect(Task.isCancelled)
			}

			queue.enqueue(context2) {
				try? await Task.sleep(nanoseconds: 1000000)
				if !Task.isCancelled {
					confirmation()
				}
				#expect(Task.isCancelled)
			}

			queue.enqueue(context3) {
				try? await Task.sleep(nanoseconds: 1000000)
				if !Task.isCancelled {
					confirmation()
				}
				#expect(Task.isCancelled)
			}

			queue.cancel([context1, context2, context3])

			while queue.totalCount > 0 {
				try await Task.sleep(nanoseconds: 10000)
			}
		}
	}

	@Test func publicAccess() {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		_ = queue.runningCount
		_ = queue.maxConcurrentCount
		_ = queue.totalCount
	}

	@Test func updateConcurrentNumberWhenRunning() async throws {
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
				try await Task.sleep(nanoseconds: 10000)
			}
		}
	}

	@Test func cancelAll() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 10)
		let allOperationCount = 10

		await confirmation("all cancelled, no confirmation called", expectedCount: 0) { confirmation in
			(0 ..< allOperationCount).forEach { _ in
				queue.enqueue(.init(id: UUID())) {
					try? await Task.sleep(nanoseconds: 100000000)
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
}

extension OperationQueueTests {
	struct TestContextObject: Identifiable, Hashable {
		var id: UUID
	}
}

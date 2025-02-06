@testable import OperationQueue
import XCTest

final class OperationQueueTests: XCTestCase {
	actor FulfilledContext {
		var fulfilled: [XCTestExpectation]

		init(fulfilled: [XCTestExpectation]) {
			self.fulfilled = fulfilled
		}
	}

	func testInit() {
		_ = ConcurrentOperationQueue<TestContextObject>()
	}

	func testDefaultMaxConcurrentOperationCount() {
		let defaultCount = ConcurrentOperationQueue<TestContextObject>()
			.maxConcurrentCount

		XCTAssertEqual(defaultCount, 1)
	}

	func testUpdateMaxConcurrentOperationCount() async {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		let newCount = 5
		queue.maxConcurrentCount = newCount
		let updatedCount = queue.maxConcurrentCount

		XCTAssertEqual(newCount, updatedCount)
	}

	func testMaxConcurrentOperationCount() async throws {
		let taskCompletedMinTime: UInt64 = 100
		let taskCompletedMaxTime: UInt64 = 10000000
		let maxCount = 10
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: maxCount)

		for _ in 0 ..< 200 {
			queue.enqueue(.init(id: UUID())) { [weak queue] in
				guard let queue = queue else { return }
				let valid = queue.isValidRunningCount
				XCTAssertTrue(valid)
				let taskCompletedTime = UInt64.random(in: taskCompletedMinTime ... taskCompletedMaxTime)
				try? await Task.sleep(nanoseconds: taskCompletedTime)
			}
		}

		while queue.totalCount > 0 {
			try await Task.sleep(nanoseconds: 10000)
		}

		XCTAssertEqual(queue.totalCount, 0)
	}

	func testCancelWhenEnqueue() async {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		let context = TestContextObject(id: UUID())
		queue.enqueue(context) {
			try? await Task.sleep(nanoseconds: 500000000)
			XCTAssertTrue(Task.isCancelled)
		}

		queue.cancel(context)
		XCTAssertEqual(queue.totalCount, 0)
	}

	func testDeinit() async {
		var queue = ConcurrentOperationQueue<TestContextObject>()
		let context = TestContextObject(id: UUID())

		let expectation = XCTestExpectation(description: "cancel all when deinit")
		queue.enqueue(context) {
			try? await Task.sleep(nanoseconds: 100000000)
			XCTAssertTrue(Task.isCancelled)
			expectation.fulfill()
		}

		XCTAssertEqual(queue.totalCount, 1)
		try? await Task.sleep(nanoseconds: 50000000)

		// reassign to deinit the first queue
		queue = ConcurrentOperationQueue()
		await fulfillment(of: [expectation], timeout: 2)
	}

	func testCancelMultipleContextObjects() async {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 3)
		let context1 = TestContextObject(id: UUID())
		let context2 = TestContextObject(id: UUID())
		let context3 = TestContextObject(id: UUID())

		let expectations = [
			XCTestExpectation(description: "context1"),
			XCTestExpectation(description: "context2"),
			XCTestExpectation(description: "context3"),
		]

		queue.enqueue(context1) {
			try? await Task.sleep(nanoseconds: 200000000)
			XCTAssertTrue(Task.isCancelled)
			expectations[0].fulfill()
		}

		queue.enqueue(context2) {
			try? await Task.sleep(nanoseconds: 200000000)
			XCTAssertTrue(Task.isCancelled)
			expectations[1].fulfill()
		}

		queue.enqueue(context3) {
			try? await Task.sleep(nanoseconds: 200000000)
			XCTAssertTrue(Task.isCancelled)
			expectations[2].fulfill()
		}

		// make sure each operation running then cancel all
		try? await Task.sleep(nanoseconds: 100000000)
		queue.cancel([context1, context2, context3])
		XCTAssertEqual(queue.totalCount, 0)

		await fulfillment(of: expectations, timeout: 2)
	}

	func testPublicAccess() {
		let queue = ConcurrentOperationQueue<TestContextObject>()
		_ = queue.runningCount
		_ = queue.maxConcurrentCount
		_ = queue.totalCount
	}

	func testUpdateConcurrentNumberWhenRunning() async {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 3)
		let allOperationCount = 200
		let taskCompletedMinTime: UInt64 = 100
		let taskCompletedMaxTime: UInt64 = 10000000

		let context = FulfilledContext(fulfilled: (0 ..< allOperationCount).map { index in
			XCTestExpectation(description: "\(index)")
		})

		for taskNumber in 0 ..< allOperationCount {
			queue.enqueue(.init(id: UUID())) { [weak queue, taskNumber] in
				guard let queue = queue else { return }
				XCTAssertTrue(queue.isValidRunningCount)
				if queue.isValidRunningCount {
					await context.fulfilled[taskNumber].fulfill()
				}
				let taskCompletedTime = UInt64.random(in: taskCompletedMinTime ... taskCompletedMaxTime)
				try? await Task.sleep(nanoseconds: taskCompletedTime)

				if taskNumber % 10 == 0 {
					queue.maxConcurrentCount += 1
				}
			}
		}

		await fulfillment(of: context.fulfilled, timeout: 10)
	}

	func testCancelAll() async throws {
		let queue = ConcurrentOperationQueue<TestContextObject>(maxConcurrentOperationCount: 10)
		let allOperationCount = 10

		let context = FulfilledContext(fulfilled: (0 ..< allOperationCount).map { index in
			XCTestExpectation(description: "\(index)")
		})

		for taskNumber in 0 ..< allOperationCount {
			queue.enqueue(.init(id: UUID())) { [taskNumber] in
				try? await Task.sleep(nanoseconds: 100000000)
				XCTAssertTrue(Task.isCancelled)
				await context.fulfilled[taskNumber].fulfill()
			}
		}

		XCTAssertEqual(10, queue.totalCount)
		try await Task.sleep(nanoseconds: 50000000)
		XCTAssertEqual(10, queue.runningCount)

		queue.cancelAll()
		await fulfillment(of: context.fulfilled, timeout: 10)
	}
}

extension OperationQueueTests {
	struct TestContextObject: Identifiable, Hashable {
		var id: UUID
	}
}

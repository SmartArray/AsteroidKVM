@testable import CometMedia
import XCTest

final class AudioRouteOperationTests: XCTestCase {
  // Simulate a driver that ignores cancellation. The UI must regain control, further
  // switches must not queue up, and the late completion must not resume twice.
  @MainActor func testStalledDriverTimesOutRejectsMoreWorkAndRecovers() async {
    let executor = AudioRouteOperation(timeout: 0.1)
    let started = expectation(description: "Driver entered")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let task = Task {
      await executor.run { started.fulfill(); release.wait(); return true }
    }
    await fulfillment(of: [started], timeout: 2)
    let result = await task.value
    XCTAssertEqual(result, .timedOut)
    for _ in 0..<20 {
      let rejected = await executor.run { XCTFail("Queued work behind a stalled driver"); return true }
      XCTAssertEqual(rejected, .busy)
    }
    release.signal()
    await drain(executor)
    let recovered = await executor.run { true }
    XCTAssertEqual(recovered, .success)
  }

  func testCancellationReturnsWithoutStartingAnotherNativeCall() async {
    let executor = AudioRouteOperation(timeout: 10)
    let started = expectation(description: "Driver entered")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let task = Task {
      await executor.run { started.fulfill(); release.wait(); return true }
    }
    await fulfillment(of: [started], timeout: 2)
    task.cancel()
    let result = await task.value
    XCTAssertEqual(result, .cancelled)
    let rejected = await executor.run { XCTFail("Cancellation cannot interrupt a driver"); return true }
    XCTAssertEqual(rejected, .busy)
    release.signal()
    await drain(executor)
    let failed = await executor.run { false }
    XCTAssertEqual(failed, .failed)
  }

  func testCancelledQueuedOperationNeverTouchesDriver() async {
    let executor = AudioRouteOperation(timeout: 10)
    let blocked = expectation(description: "Queue blocked")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    executor.queue.async { blocked.fulfill(); release.wait() }
    await fulfillment(of: [blocked], timeout: 2)
    let task = Task {
      await executor.run { XCTFail("Cancelled route should not start"); return true }
    }
    task.cancel()
    let result = await task.value
    XCTAssertEqual(result, .cancelled)
    release.signal()
    await drain(executor)
  }

  private func drain(_ executor: AudioRouteOperation) async {
    await withCheckedContinuation { continuation in
      executor.queue.async { continuation.resume() }
    }
  }
}

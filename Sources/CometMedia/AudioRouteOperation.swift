import Foundation

// Driver calls cannot be interrupted. Bound the caller's wait and admit only one native call,
// even after timeout/cancellation; never accumulate work behind an unresponsive driver.
final class AudioRouteOperation: @unchecked Sendable {
  enum Result: Equatable { case success, failed, timedOut, busy, cancelled }
  let queue = DispatchQueue(label: "app.asteroidkvm.audio-output", qos: .userInitiated)
  private let lock = NSLock()
  private var running = false
  private let timeout: TimeInterval

  init(timeout: TimeInterval = 5) { self.timeout = timeout }

  func run(_ operation: @escaping @Sendable () -> Bool) async -> Result {
    let reply = Reply()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        reply.install(continuation)
        guard !Task.isCancelled else { reply.finish(.cancelled); return }
        lock.lock()
        guard !running else { lock.unlock(); reply.finish(.busy); return }
        running = true
        lock.unlock()
        let deadline = DispatchWorkItem { reply.finish(.timedOut) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: deadline)
        queue.async { [self] in
          let result: Result = reply.isFinished ? .cancelled : (operation() ? .success : .failed)
          lock.lock()
          running = false
          lock.unlock()
          deadline.cancel()
          reply.finish(result)
        }
      }
    } onCancel: { reply.finish(.cancelled) }
  }

  private final class Reply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?
    private var result: Result?
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }

    func install(_ continuation: CheckedContinuation<Result, Never>) {
      lock.lock()
      if let result { lock.unlock(); continuation.resume(returning: result) }
      else { self.continuation = continuation; lock.unlock() }
    }

    func finish(_ result: Result) {
      lock.lock()
      guard self.result == nil else { lock.unlock(); return }
      self.result = result
      let continuation = self.continuation
      self.continuation = nil
      lock.unlock()
      continuation?.resume(returning: result)
    }
  }
}

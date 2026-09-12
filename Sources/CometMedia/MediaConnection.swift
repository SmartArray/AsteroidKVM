import CometCore
// Let session orchestration depend on a media lifecycle contract, independently of its Janus implementation.
import Foundation

@MainActor public protocol MediaConnection: AnyObject {
  var onError: ((Error) -> Void)? { get set }
  var onConnected: (() -> Void)? { get set }
  var onFeatures: ((JSONValue) -> Void)? { get set }

  // Start this media connection using explicit microphone and playback preferences.
  func start(microphone: Bool, muted: Bool) async throws

  // Change local playback without altering the appliance’s remote USB audio function.
  func setMuted(_ muted: Bool)

  // Cancel owned asynchronous work and release resources without affecting another session.
  func stop()
}

// The production implementation uses the same interface exercised by session lifecycle tests.
extension JanusClient: MediaConnection {}

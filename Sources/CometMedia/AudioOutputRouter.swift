import Foundation
@preconcurrency import WebRTC

// Serialize potentially slow driver operations away from the UI, retaining the factory's worker thread.
final class AudioOutputRouter: @unchecked Sendable {
  private let operation = AudioRouteOperation()
  private var queue: DispatchQueue { operation.queue }
  // A failed restart may leave the native state disabled. Retain the intended state
  // so selecting a working device can restore playback and microphone forwarding.
  // Accessed only on the operation queue.
  private weak var recoveryFactory: RTCPeerConnectionFactory?
  private var recoveryState: (availability: RTCAudioEngineAvailability, wasRunning: Bool)?

  func select(_ uid: String?, factory: RTCPeerConnectionFactory) async -> AudioRouteOperation.Result {
    await operation.run { [self] in
      let module = factory.audioDeviceModule
      let device = uid.flatMap { uid in module.outputDevices.first { $0.deviceId == uid } }
      guard uid == nil || device != nil else { return false }
      // Availability changes preserve the route, voice processing, and requested I/O state.
      // Do not use the SDK's engineState setter: it resets native fields not exposed by
      // the Objective-C struct, including the selected device and processing policy.
      let saved = recoveryFactory === factory ? recoveryState : nil
      let availability = saved?.availability ?? module.engineAvailability
      let wasRunning = saved?.wasRunning ?? module.isEngineRunning
      recoveryFactory = factory
      recoveryState = (availability, wasRunning)
      guard module.setEngineAvailability(RTCAudioEngineAvailability(
        isInputAvailable: false, isOutputAvailable: false)) == 0 else { return false }
      // The pinned 150.7871.01 wrapper returns NO for native success (0), YES for failure.
      // Its AudioEngine also lacks GetPlayoutDevice. Check availability and restart too.
      let nativeFailed = module.trySetOutputDevice(device)
      let restored = module.setEngineAvailability(availability) == 0
      let stillAvailable = module.outputDevices.contains { output in
        uid.map { output.deviceId == $0 } ?? output.isDefault
      }
      let success = !nativeFailed && restored && stillAvailable && (!wasRunning || module.isEngineRunning)
      if success { recoveryFactory = nil; recoveryState = nil }
      return success
    }
  }

  // Track operations can synchronously wait for the same WebRTC worker as routing.
  func perform(factory: RTCPeerConnectionFactory, _ work: @escaping @Sendable () -> Void) {
    queue.async { withExtendedLifetime(factory, work) }
  }

  func close(peer: RTCPeerConnection?, factory: RTCPeerConnectionFactory?,
    audio: RTCAudioTrack?, microphone: RTCAudioTrack?, monitor: AudioActivityMonitor,
    video: RTCVideoTrack?, mailbox: FrameMailbox)
  {
    queue.async {
      // No queued route operation may outlive its factory or access a closed worker thread.
      withExtendedLifetime(factory) {
        microphone?.isEnabled = false
        audio?.remove(monitor)
        video?.remove(mailbox)
        peer?.close()
      }
    }
  }
}

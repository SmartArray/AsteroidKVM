import AVFoundation
import CoreAudio
@testable import CometMedia
@preconcurrency import WebRTC
import XCTest

final class AudioOutputRouterTests: XCTestCase {
  // Opt in to opening a specific physical output. Read back the AudioUnit device UID,
  // since the SDK's AudioEngine GetPlayoutDevice implementation is unavailable.
  func testNativeOutputReallyChangesDevice() async throws {
    guard let uid = ProcessInfo.processInfo.environment["ASTEROID_TEST_AUDIO_OUTPUT_UID"] else {
      throw XCTSkip("Set ASTEROID_TEST_AUDIO_OUTPUT_UID to exercise a physical output.")
    }
    let factory = RTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine,
      bypassVoiceProcessing: true, encoderFactory: RTCDefaultVideoEncoderFactory(),
      decoderFactory: RTCDefaultVideoDecoderFactory(), audioProcessingModule: nil)
    let peer = factory.peerConnection(with: RTCConfiguration(),
      constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil)
    let observer = RouteObserver()
    let executor = AudioRouteOperation()
    let router = AudioOutputRouter()
    defer {
      router.perform(factory: factory) {
        _ = factory.audioDeviceModule.stopPlayout()
        factory.audioDeviceModule.observer = nil
        peer?.close()
      }
    }
    let started = await executor.run {
      let module = factory.audioDeviceModule
      module.observer = observer
      return module.initPlayout() == 0 && module.startPlayout() == 0
    }
    guard started == .success else { XCTFail("Starting output: \(started)"); return }
    let originalUID = try XCTUnwrap(observer.outputUID)
    let selected = await router.select(uid, factory: factory)
    guard selected == .success else { XCTFail("Selecting output: \(selected)"); return }
    XCTAssertEqual(observer.outputUID, uid, "Success must mean the hardware output actually changed")
    let reset = await router.select(nil, factory: factory)
    XCTAssertEqual(reset, .success)
    XCTAssertEqual(observer.outputUID, originalUID)
  }
}

private final class RouteObserver: NSObject, RTCAudioDeviceModuleDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var uid: String?
  var outputUID: String? { lock.lock(); defer { lock.unlock() }; return uid }

  func audioDeviceModule(_ module: RTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
    isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
    guard isPlayoutEnabled, let unit = engine.outputNode.audioUnit else { return 0 }
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global, 0, &device, &size) == noErr else { return 0 }
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
    lock.lock()
    uid = value?.takeRetainedValue() as String?
    lock.unlock()
    return 0
  }

  func audioDeviceModule(_ module: RTCAudioDeviceModule, didReceiveSpeechActivityEvent event: RTCSpeechActivityEvent) {}
  func audioDeviceModuleDidUpdateDevices(_ module: RTCAudioDeviceModule) {}
  func audioDeviceModule(_ module: RTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int { 0 }
  func audioDeviceModule(_ module: RTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int { 0 }
  func audioDeviceModule(_ module: RTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
    isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
  func audioDeviceModule(_ module: RTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
    isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
  func audioDeviceModule(_ module: RTCAudioDeviceModule, engine: AVAudioEngine,
    configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode,
    format: AVAudioFormat, context: [AnyHashable: Any]) -> Int { 0 }
  func audioDeviceModule(_ module: RTCAudioDeviceModule, engine: AVAudioEngine,
    configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?,
    format: AVAudioFormat, context: [AnyHashable: Any]) -> Int { 0 }
}

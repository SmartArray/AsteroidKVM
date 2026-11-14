import Combine
import CoreAudio
import Foundation

public struct AudioOutputDevice: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
}

// Enumerate hardware, virtual, aggregate, and Multi-Output devices through the same HAL as Audio MIDI Setup.
@MainActor public final class AudioOutputDevices: ObservableObject {
  public static let shared = AudioOutputDevices()
  @Published public private(set) var devices: [AudioOutputDevice] = []
  @Published public private(set) var defaultDeviceUID: String?
  private let enumerationQueue = DispatchQueue(label: "app.asteroidkvm.audio-devices", qos: .utility)
  private var refreshing = false
  private var refreshAgain = false
  private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

  public init() {
    refresh()
    for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
      var address = Self.address(selector)
      let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.refresh() }
      }
      if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
        .main, callback) == noErr { listeners.append((address, callback)) }
    }
  }

  deinit {
    for (var address, callback) in listeners {
      AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, callback)
    }
  }

  public func refresh() {
    guard !refreshing else { refreshAgain = true; return }
    refreshing = true
    enumerationQueue.async { [weak self] in
      let snapshot = Self.readDevices()
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let snapshot {
          if defaultDeviceUID != snapshot.defaultUID { defaultDeviceUID = snapshot.defaultUID }
          if devices != snapshot.devices { devices = snapshot.devices }
        }
        refreshing = false
        if refreshAgain { refreshAgain = false; refresh() }
      }
    }
  }

  // HAL property reads can wait for a driver. Never enumerate on the UI thread.
  private nonisolated static func readDevices() -> (devices: [AudioOutputDevice], defaultUID: String?)? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = Self.address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
    guard size > 0 else { return ([], nil) }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = ids.withUnsafeMutableBytes {
      AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { return nil }
    let available = ids.compactMap { id -> AudioOutputDevice? in
      var output = Self.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
      var bytes: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(id, &output, 0, nil, &bytes) == noErr,
        bytes >= MemoryLayout<AudioBufferList>.size else { return nil }
      let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
      defer { memory.deallocate() }
      guard AudioObjectGetPropertyData(id, &output, 0, nil, &bytes, memory) == noErr else { return nil }
      let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
      guard buffers.contains(where: { $0.mNumberChannels > 0 }),
        let uid = Self.string(id, kAudioDevicePropertyDeviceUID),
        let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
      return AudioOutputDevice(id: uid, name: name)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    var defaultID = AudioObjectID(kAudioObjectUnknown)
    address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    size = UInt32(MemoryLayout<AudioObjectID>.size)
    let defaultUID = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &defaultID) == noErr
      ? Self.string(defaultID, kAudioDevicePropertyDeviceUID) : nil
    return (available, defaultUID)
  }

  private nonisolated static func address(_ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress
  {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
  }
}

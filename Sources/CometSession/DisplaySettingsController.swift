// Own per-device drafts and reversible EDID writes independently of SwiftUI and live video rendering.
import Combine
import CometCore
import CryptoKit
import Foundation

@MainActor public final class DisplaySettingsController: ObservableObject {
  @Published public private(set) var current: EDIDDocument?
  @Published public private(set) var draft: EDIDDocument?
  @Published public private(set) var previous: EDIDDocument?
  @Published public private(set) var model = ""
  @Published public private(set) var busy = false
  @Published public private(set) var loaded = false
  @Published public private(set) var message: String?
  @Published public var manufacturer = ""
  @Published public var product = ""
  @Published public var serial = ""
  @Published public var week = ""
  @Published public var year = ""
  private let service: () -> (any EDIDService)?
  private let endpoint: () -> String
  private let beforeApply: () -> Void
  private let backupDirectory: URL
  private var loadedEndpoint: String?

  // Dependencies are resolved at operation start so reconnects use fresh credentials without carrying drafts across hosts.
  public init(
    service: @escaping () -> (any EDIDService)?, endpoint: @escaping () -> String,
    backupDirectory: URL? = nil, beforeApply: @escaping () -> Void = {}
  ) {
    self.service = service
    self.endpoint = endpoint
    self.beforeApply = beforeApply
    self.backupDirectory =
      backupDirectory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("CometKVM/EDIDBackups", isDirectory: true)
  }

  // Only confirmed hardware models enable the curated timing templates.
  public var isCurrent: Bool { loaded && loadedEndpoint == endpoint() }

  // Recovery remains available after a failed read, but only for the backup bound to this exact endpoint.
  public var canRestore: Bool { !busy && previous != nil && loadedEndpoint == endpoint() }
  public var presets: [EDIDPreset] { EDIDPreset.supported(model: model) }
  public var validationMessage: String? {
    do {
      _ = try proposal()
      return nil
    } catch { return error.localizedDescription }
  }
  public var canApply: Bool {
    guard loaded, !busy, loadedEndpoint == endpoint(), let value = try? proposal() else {
      return false
    }
    return value != current
  }

  // Parse user input without truncating integer ranges or silently replacing malformed fields.
  public func proposal() throws -> EDIDDocument {
    guard let draft else { throw EDIDError("Choose a target resolution profile first.") }
    func hex(_ value: String) -> String {
      let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return v.lowercased().hasPrefix("0x") ? String(v.dropFirst(2)) : v
    }
    guard let p = UInt16(hex(product), radix: 16), let s = UInt32(hex(serial), radix: 16),
      let w = UInt8(week), let y = Int(year)
    else {
      throw EDIDError("Enter valid hexadecimal product/serial values and numeric week/year values.")
    }
    return try draft.replacingIdentity(
      EDIDIdentity(
        manufacturer: manufacturer, product: p,
        serial: s, week: w, year: y))
  }

  // Replacing a timing profile preserves the edited identity while installing a complete audio-capable template.
  public func select(_ preset: EDIDPreset) {
    guard !busy, isCurrent, presets.contains(preset) else { return }
    let identity = (try? proposal().identity) ?? draft?.identity ?? .example
    do {
      setDraft(try preset.document(identity: identity))
      message = nil
    } catch { message = error.localizedDescription }
  }

  // Populate the supplied example explicitly, never on initial read of an existing monitor identity.
  public func useExampleIdentity() {
    guard !busy, draft != nil else { return }
    setFields(.example)
  }

  // Reads and discards share one path; errors retain the draft but disable Apply until a fresh read succeeds.
  public func reload() async {
    guard !busy else { return }
    busy = true
    loaded = false
    message = nil
    defer { busy = false }
    let key = endpoint()
    if key != loadedEndpoint {
      current = nil
      draft = nil
      previous = nil
      model = ""
    }
    guard let api = service() else {
      message = "Connect this Comet to load display settings."
      return
    }
    do {
      // Load recovery bytes before querying firmware so an unreadable current EDID cannot hide its backup.
      previous = try loadBackup(key)
      loadedEndpoint = key
      let document = try await api.readEDID()
      let detectedModel = try await api.readDisplayModel()
      guard key == endpoint() else { return }
      current = document
      model = detectedModel
      setDraft(document)
      loaded = true
    } catch { if key == endpoint() { message = error.localizedDescription } }
  }

  // Resolve and validate the full draft before entering the shared serialized write workflow.
  public func apply() async {
    guard canApply else { return }
    do { try await write(proposal(), restoring: false) } catch {
      message = error.localizedDescription
    }
  }

  // Restore the exact captured bytes, including capabilities not exposed by this editor.
  public func restore() async {
    guard canRestore, let previous else { return }
    do { try await write(previous, restoring: true) } catch { message = error.localizedDescription }
  }

  // Check for external changes and persist a recoverable baseline before the first device mutation.
  private func write(_ document: EDIDDocument, restoring: Bool) async throws {
    guard let api = service() else { throw EDIDError("Reconnect this Comet before applying EDID.") }
    let key = endpoint()
    busy = true
    defer { busy = false }
    // Restoring known-good bytes must not depend on decoding a potentially broken current document.
    if !restoring {
      let baseline = try await api.readEDID()
      guard key == endpoint() else {
        throw EDIDError("The connection changed. Reload display settings.")
      }
      guard baseline == current else {
        throw EDIDError("EDID changed on the Comet. Discard changes to reload it before applying.")
      }
      try saveBackup(baseline, key: key)
      previous = baseline
    }
    beforeApply()
    message = "Applying EDID. HDMI video may briefly disappear…"

    // A failed or interrupted upload is ambiguous: keep the backup and require a reload, never retry automatically.
    do {
      try await api.writeEDID(document)
      let readback = try await api.readEDID()
      guard key == endpoint() else {
        throw EDIDError("The connection changed. Reload display settings.")
      }
      guard readback == document else {
        throw EDIDError(
          "EDID readback differs from the submitted settings. Reload or restore the previous EDID.")
      }
      current = readback
      loaded = true
      setDraft(readback)
      message =
        "EDID saved and verified. Check the received video resolution; the target may need a display adjustment or restart."
    } catch {
      loaded = false
      throw EDIDError(
        "\(error.localizedDescription) The write may have taken effect. Reload before trying again; the previous EDID backup is retained."
      )
    }
  }

  // Keep field editing separate from the source bytes so invalid partial text never mutates a valid document.
  private func setDraft(_ document: EDIDDocument?) {
    draft = document
    if let identity = document?.identity {
      setFields(identity)
    } else {
      manufacturer = ""
      product = ""
      serial = ""
      week = ""
      year = ""
    }
  }
  private func setFields(_ identity: EDIDIdentity) {
    manufacturer = identity.manufacturer
    product = String(format: "0x%04X", identity.product)
    serial = String(format: "0x%08X", identity.serial)
    week = String(identity.week)
    year = String(identity.year)
  }

  // Hash the connection UUID and endpoint to prevent file-path injection and restoration onto another device.
  private func backupURL(_ key: String) -> URL {
    let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return backupDirectory.appendingPathComponent(name + ".hex")
  }
  private func loadBackup(_ key: String) throws -> EDIDDocument? {
    let url = backupURL(key)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try EDIDDocument(hex: String(contentsOf: url, encoding: .utf8))
  }
  private func saveBackup(_ value: EDIDDocument?, key: String) throws {
    try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
    let url = backupURL(key)
    if let value {
      try value.hex.write(to: url, atomically: true, encoding: .utf8)
    } else if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}

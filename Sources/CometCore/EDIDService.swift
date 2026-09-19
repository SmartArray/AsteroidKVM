// Keep EDID transport behind a small interface so session workflows can be tested without hardware.
import Foundation

public protocol EDIDService: Sendable {
  func readEDID() async throws -> EDIDDocument?
  func readDisplayModel() async throws -> String
  func writeEDID(_ document: EDIDDocument) async throws
}

extension CometAPI: EDIDService {
  // Empty firmware state means an unreadable factory default, not a fabricated restorable document.
  public func readEDID() async throws -> EDIDDocument? {
    do {
      let value = try await call("/api/upgrade/get_edid")
      guard let hex = value["edid"].string else { throw CometError.invalidResponse }
      return hex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil : try EDIDDocument(hex: hex)
    } catch CometError.server(let code) where [404, 405, 501].contains(code) {
      throw CometError.unsupported("This firmware does not expose EDID configuration.")
    }
  }

  // Firmware version metadata carries the actual Comet model; the legacy /info platform model does not.
  public func readDisplayModel() async throws -> String {
    do {
      return try await call("/api/upgrade/version")["model"].string ?? ""
    } catch CometError.server(let code) where [404, 405, 501].contains(code) { return "" }
  }

  // Match the appliance web client's multipart field and reuse the scoped authenticated transport.
  public func writeEDID(_ document: EDIDDocument) async throws {
    let form = Self.edidForm(document)
    do {
      try await call(
        "/api/upgrade/edid", method: "POST", body: form.body,
        contentType: form.contentType, timeout: 60)
    } catch CometError.server(400) {
      throw EDIDError("The Comet rejected this EDID. Reload to check its current configuration.")
    }
  }

  // Expose deterministic multipart construction for protocol tests without exposing authentication tokens.
  public nonisolated static func edidForm(_ document: EDIDDocument) -> (
    body: Data, contentType: String
  ) {
    let boundary = "AsteroidEDIDBoundary"
    let body =
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"edid\"\r\n\r\n\(document.hex)\r\n--\(boundary)--\r\n"
    return (Data(body.utf8), "multipart/form-data; boundary=\(boundary)")
  }
}

// Guard SwiftUI dismantling against synchronous ObservableObject publication and verify eventual cleanup.
import AppKit
import Combine
import CometCore
import CometSession
import XCTest

@MainActor final class RemoteSurfaceLifecycleTests: XCTestCase {
  // Observe real session publications while dismantling the surface, including repeated AppKit cleanup.
  func testTeardownDefersSessionPublicationAndReleasesCapture() async throws {
    let session = SessionController(
      profile: ConnectionProfile(name: "Lifecycle Test", host: "fixture.invalid"))
    let surface = RemoteSurface(session: session)
    session.captured = true
    session.ocrSelecting = true
    session.ocrBusy = true
    var publications = 0
    let observation = session.objectWillChange.sink { publications += 1 }
    defer { observation.cancel() }

    // The representable destruction callback must not reenter SwiftUI's graph through any published property.
    surface.teardown()
    surface.teardown()
    XCTAssertTrue(surface.resignFirstResponder())
    XCTAssertEqual(publications, 0)
    XCTAssertFalse(surface.allowsAutomaticCapture)

    // A main-actor turn must still release capture and cancel OCR after the synchronous callback returns.
    for _ in 0..<100 where session.captured || session.ocrSelecting || session.ocrBusy {
      await Task.yield()
    }
    XCTAssertFalse(session.captured)
    XCTAssertFalse(session.ocrSelecting)
    XCTAssertFalse(session.ocrBusy)
    XCTAssertGreaterThan(publications, 0)
  }
}

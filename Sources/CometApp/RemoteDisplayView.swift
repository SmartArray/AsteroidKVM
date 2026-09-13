import CometCore
import CometMedia
import CometSession
import MetalKit
// Bridge precise AppKit input and a stable Metal surface into the native SwiftUI window.
import SwiftUI

struct RemoteDisplayView: NSViewRepresentable {
  @ObservedObject var session: SessionController
  var allowsAutomaticCapture = true

  // Create the AppKit display once so SwiftUI updates cannot recreate its media surface.
  func makeNSView(context: Context) -> RemoteSurface {
    let view = RemoteSurface(session: session)
    view.allowsAutomaticCapture = allowsAutomaticCapture
    return view
  }

  // Synchronize presentation preferences on the existing AppKit surface.
  func updateNSView(_ view: RemoteSurface, context: Context) {
    view.allowsAutomaticCapture = allowsAutomaticCapture
    view.synchronize()
  }

  // Remove observers and capture when SwiftUI removes the remote display.
  static func dismantleNSView(_ nsView: RemoteSurface, coordinator: ()) { nsView.teardown() }
}

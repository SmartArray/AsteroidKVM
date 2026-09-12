import CometCore
import CometMedia
import CometSession
import MetalKit
// Bridge precise AppKit input and a stable Metal surface into the native SwiftUI window.
import SwiftUI

struct RemoteDisplayView: NSViewRepresentable {
  @ObservedObject var session: SessionController

  // Create the AppKit display once so SwiftUI updates cannot recreate its media surface.
  func makeNSView(context: Context) -> RemoteSurface { RemoteSurface(session: session) }

  // Synchronize presentation preferences on the existing AppKit surface.
  func updateNSView(_ view: RemoteSurface, context: Context) { view.synchronize() }

  // Remove observers and capture when SwiftUI removes the remote display.
  static func dismantleNSView(_ nsView: RemoteSurface, coordinator: ()) { nsView.teardown() }
}

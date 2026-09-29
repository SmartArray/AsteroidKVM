import SwiftUI

struct GestureOnboardingView: View {
  var finish: () -> Void
  @State private var page = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let titles: [LocalizedStringKey] = ["Point and click", "Pan and zoom", "Scroll remotely", "Your controls, within reach"]
  private let explanations: [LocalizedStringKey] = [
    "Move one finger to position the pointer. Tap to click. Absolute mode is on by default; choose Trackpad in Settings.",
    "Drag with two fingers to move the view. Pinch to zoom. These gestures change your view, not the remote computer.",
    "Position the pointer over the area you want to scroll, then swipe with three fingers.",
    "Tap the round button to open controls. Drag it to move it to another corner."
  ]
  private let artwork = ["GesturePointer", "GesturePanZoom", "GestureScroll"]
  @State private var previewMenu = false
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            Text(titles[page]).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(explanations[page]).font(.body)
            if page == 0 { Text("Long-press to right-click. Double-tap, hold, and move to drag. Double-tap to double-click.").font(.callout).foregroundStyle(.secondary) }
            if page == 2 { Text("Some iOS accessibility and editing gestures may take priority over three-finger scrolling. VoiceOver users can use the remote view’s scroll actions.").font(.callout).foregroundStyle(.secondary) }
            if page < 3 {
              Image(artwork[page]).resizable().scaledToFit().frame(maxWidth: 520).clipShape(RoundedRectangle(cornerRadius: 24)).frame(maxWidth: .infinity).accessibilityHidden(true)
              GestureAnimation(page: page, reduceMotion: reduceMotion).frame(height: 54).accessibilityHidden(true)
            } else {
              ZStack {
                RoundedRectangle(cornerRadius: 24).fill(Color(red: 0.035, green: 0.035, blue: 0.1))
                VStack(spacing: 12) {
                  Image(systemName: "desktopcomputer").font(.system(size: 64)).foregroundStyle(.indigo)
                  Text(previewMenu ? "Type · Special keys · Shortcuts\nSettings · OCR · Close connection" : "Try moving the button").foregroundStyle(.white).multilineTextAlignment(.center)
                }.padding(60)
                FloatingMenuButton { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { previewMenu.toggle() } }
              }.frame(height: 320)
              Text("Type opens a native editor with system paste. Send returns you straight to the screen. Hold Close connection for two seconds to disconnect.").font(.callout).foregroundStyle(.secondary)
            }
          }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        HStack(spacing: 8) { ForEach(0..<4) { index in Circle().fill(page == index ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 8, height: 8) } }
          .accessibilityElement(children: .ignore).accessibilityLabel("Page \(page+1) of 4").padding(12)
        HStack {
          Button("Back") { change(-1) }.disabled(page == 0)
          Spacer()
          Button(page == 3 ? "Get Started" : "Next") { if page == 3 { finish() } else { change(1) } }.buttonStyle(.borderedProminent)
        }.padding(.horizontal,24).padding(.bottom,16)
      }
      .navigationTitle("Gesture Guide").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Skip", action: finish) } }
    }
  }
  private func change(_ amount: Int) { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page += amount } }
}

private struct GestureAnimation: View {
  let page: Int
  let reduceMotion: Bool
  @State private var animate = false
  var body: some View {
    HStack(spacing: page == 1 && animate ? 36 : 14) {
      ForEach(0..<(page+1),id: \.self) { _ in Circle().fill(.teal.opacity(0.5)).overlay(Circle().stroke(.teal,lineWidth: 2)).frame(width: 16,height: 16) }
    }
    .offset(x: page == 0 && animate ? 24 : 0, y: page == 2 && animate ? -12 : 0)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.8).repeatCount(4,autoreverses: true)) { animate = true }
    }.id(page)
  }
}

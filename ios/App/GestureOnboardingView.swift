import SwiftUI

struct GestureOnboardingView: View {
  var finish: () -> Void
  @State private var page = 0
  @State private var previewMenu = false
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let titles: [LocalizedStringKey] = [
    "Point and click", "Pan and zoom", "Scroll remotely", "Your controls, within reach",
  ]
  private let explanations: [LocalizedStringKey] = [
    "Move one finger to position the pointer. Tap to click. Absolute mode is on by default; choose Trackpad in Settings.",
    "Drag with two fingers to move the view. Pinch to zoom. These gestures change your view, not the remote computer.",
    "Position the pointer over the area you want to scroll, then swipe with three fingers.",
    "Tap the round button to open controls. Drag it to move it to another corner.",
  ]
  private let artwork = ["GesturePointer", "GesturePanZoom", "GestureScroll"]
  private let gestures = ["ONE FINGER", "TWO FINGERS", "THREE FINGERS", "MAKE IT YOURS"]
  private var palette: GuidePalette { GuidePalette(dark: colorScheme == .dark) }

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let wide = geometry.size.width > 680 && !typeSize.isAccessibilitySize
        ScrollView {
          VStack(spacing: geometry.size.height < 450 ? 8 : 24) {
            HStack {
              if geometry.size.height >= 450 { Text("ASTEROIDKVM").tracking(2) }
              Spacer()
              Text(String(format: "%02d / 04", page + 1)).monospacedDigit()
            }
            .font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .ignore).accessibilityLabel("Page \(page + 1) of 4")
            .accessibilityValue(colorScheme == .dark ? "Dark appearance" : "Light appearance")
            .accessibilityIdentifier("guide-progress")
            if wide {
              HStack(alignment: geometry.size.height < 450 ? .top : .center, spacing: 40) {
                illustration(
                  edge: min(380, geometry.size.width * 0.43, max(120, geometry.size.height - 240)))
                explanation.frame(maxWidth: 380, alignment: .leading)
              }
              .frame(minHeight: max(0, geometry.size.height - 210))
            } else {
              illustration(
                edge: min(
                  330, geometry.size.width - 48,
                  max(200, geometry.size.height * (page == 3 ? 0.29 : 0.34))))
              explanation
            }
          }
          .frame(maxWidth: wide ? 920 : 520)
          .padding(24).frame(maxWidth: .infinity)
        }
        .id(page)
        .safeAreaInset(edge: .bottom, spacing: 0) { navigation }
        .background(palette.background.ignoresSafeArea())
      }
      .navigationTitle("Gesture Guide").navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(palette.background, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Skip", action: finish).foregroundStyle(palette.secondary)
        }
      }
      .tint(palette.accent)
    }
  }

  private func illustration(edge: CGFloat) -> some View {
    Group {
      if page < 3 {
        // Asset-catalog appearance variants follow both System and the app's appearance override.
        Image(artwork[page]).resizable().scaledToFit().accessibilityHidden(true)
      } else {
        controlsPreview
      }
    }
    .frame(width: edge, height: edge)
    .background(palette.card)
    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .strokeBorder(palette.outline, lineWidth: 1)
    }
    .shadow(color: palette.shadow, radius: 24, x: 0, y: 12)
  }

  private var explanation: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 7) {
        RoundedRectangle(cornerRadius: 2).fill(palette.teal).frame(width: 4, height: 14)
        Text(gestures[page]).font(.caption.weight(.bold)).tracking(1.6)
          .foregroundStyle(palette.accent)
      }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).accessibilityHidden(true)
      Text(titles[page]).font(.largeTitle.weight(.bold)).tracking(-0.8)
        .foregroundStyle(palette.primary).fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      Text(explanations[page]).font(.body).lineSpacing(4)
        .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
      if page == 0 {
        note(
          "Long-press to right-click. Double-tap, hold, and move to drag. Double-tap to double-click.",
          symbol: "hand.tap")
      } else if page == 1 {
        note(
          "Your view, your perspective. Pinch out for a closer look; pinch in to see more.",
          symbol: "arrow.up.left.and.arrow.down.right")
      } else if page == 2 {
        note(
          "Some iOS accessibility and editing gestures may take priority over three-finger scrolling. VoiceOver users can use the remote view’s scroll actions.",
          symbol: "accessibility")
      } else {
        note(
          "Keyboard keeps typing within reach. Type opens a text editor. Hold Close connection for one second to disconnect.",
          symbol: "keyboard")
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func note(_ text: LocalizedStringKey, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).font(.callout.weight(.semibold)).foregroundStyle(palette.accent)
        .frame(width: 22).padding(.top, 2).accessibilityHidden(true)
      Text(text).font(.callout).lineSpacing(3).foregroundStyle(palette.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var controlsPreview: some View {
    ZStack {
      LinearGradient(
        colors: [palette.card, palette.preview], startPoint: .topLeading, endPoint: .bottomTrailing)
      ViewThatFits(in: .vertical) {
        VStack(spacing: 12) {
          Image(systemName: previewMenu ? "keyboard" : "desktopcomputer")
            .font(.system(size: 36, weight: .light)).foregroundStyle(palette.accent)
          Text(previewMenu ? "A shortcut to everything." : "Always within reach.")
            .font(.headline).foregroundStyle(palette.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          Text(
            previewMenu
              ? "Keyboard · Type · Special keys\nShortcuts · Settings · OCR"
              : "Try tapping or moving\nthe floating button."
          )
          .font(.caption).lineSpacing(3).foregroundStyle(palette.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
        Text(previewMenu ? "A shortcut to everything." : "Try the floating button.")
          .font(.headline).foregroundStyle(palette.primary).multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(24).padding(.bottom, 28)
      FloatingMenuButton(accessibilityID: "guide-controls-preview") {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { previewMenu.toggle() }
      }
    }
  }

  private var navigation: some View {
    VStack(spacing: 18) {
      HStack(spacing: 6) {
        ForEach(0..<4) { index in
          Capsule().fill(index <= page ? palette.accent : palette.outline).frame(height: 3)
        }
      }.accessibilityHidden(true)
      HStack(spacing: 20) {
        Button {
          change(-1)
        } label: {
          if typeSize.isAccessibilitySize {
            Image(systemName: "chevron.left").font(.title3.weight(.semibold))
              .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          } else {
            Text("Back")
          }
        }
        .accessibilityLabel("Back")
        .font(.body.weight(.semibold)).foregroundStyle(palette.secondary)
        .frame(minWidth: 52, minHeight: 48).disabled(page == 0).opacity(page == 0 ? 0.3 : 1)
        Button {
          if page == 3 { finish() } else { change(1) }
        } label: {
          HStack {
            Text(page == 3 ? "Get Started" : "Next")
            Spacer()
            if !typeSize.isAccessibilitySize {
              Image(systemName: page == 3 ? "checkmark" : "arrow.right").accessibilityHidden(true)
            }
          }
          .font(.body.weight(.semibold)).foregroundStyle(.white)
          .padding(.horizontal, 22).frame(minHeight: 52)
          .background(palette.button, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }.buttonStyle(.plain)
      }
    }
    .frame(maxWidth: 520).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 16)
    .frame(maxWidth: .infinity).background(palette.background)
  }

  private func change(_ amount: Int) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
      page += amount
      previewMenu = false
    }
  }
}

private struct GuidePalette {
  let dark: Bool
  private func color(_ light: UInt32, _ night: UInt32) -> Color {
    let rgb = dark ? night : light
    return Color(
      red: Double((rgb >> 16) & 255) / 255,
      green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
  }
  var background: Color { color(0xFAF9FF, 0x090919) }
  var card: Color { color(0xF0EFFA, 0x16162E) }
  var preview: Color { color(0xE3E3FA, 0x24244C) }
  var primary: Color { color(0x20203E, 0xF3EFFF) }
  var secondary: Color { color(0x606078, 0xBBB9D2) }
  var accent: Color { color(0x4C4FD1, 0xAAA7FF) }
  var button: Color { color(0x4C4FD1, 0x5755D9) }
  var teal: Color { color(0x008C91, 0x20D4CB) }
  var outline: Color { color(0xDDDCF0, 0x333351) }
  var shadow: Color { color(0x555080, 0x000000).opacity(dark ? 0.2 : 0.08) }
}

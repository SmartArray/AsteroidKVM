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
    OnboardingPager(
      page: $page, title: "Gesture Guide", progressID: "guide-progress", finish: finish
    ) { index, size in
      let wide = size.width > 680 && !typeSize.isAccessibilitySize
      Group {
        if wide {
          HStack(alignment: size.height < 450 ? .top : .center, spacing: 40) {
            illustration(index, edge: min(380, size.width * 0.43, max(120, size.height - 240)))
            explanation(index).frame(maxWidth: 380, alignment: .leading)
          }
          .frame(minHeight: max(0, size.height - 210))
        } else {
          VStack(spacing: 24) {
            illustration(
              index,
              edge: min(330, size.width - 48, max(180, size.height * (index == 3 ? 0.29 : 0.34))))
            explanation(index)
          }
        }
      }
      .frame(maxWidth: wide ? 920 : 520)
    }
    .onChange(of: page) { _, _ in previewMenu = false }
  }

  private func illustration(_ index: Int, edge: CGFloat) -> some View {
    Group {
      if index < 3 {
        // Asset-catalog appearance variants follow both System and the app's appearance override.
        Image(artwork[index]).resizable().scaledToFit().accessibilityHidden(true)
      } else {
        controlsPreview
      }
    }
    .frame(width: max(0, edge), height: max(0, edge))
    .background(palette.card)
    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .strokeBorder(palette.outline, lineWidth: 1)
    }
    .shadow(color: palette.shadow, radius: 24, x: 0, y: 12)
  }

  private func explanation(_ index: Int) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 7) {
        RoundedRectangle(cornerRadius: 2).fill(palette.teal).frame(width: 4, height: 14)
        Text(gestures[index]).font(.caption.weight(.bold)).tracking(1.6)
          .foregroundStyle(palette.accent)
      }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).accessibilityHidden(true)
      Text(titles[index]).font(.largeTitle.weight(.bold)).tracking(-0.8)
        .foregroundStyle(palette.primary).fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      Text(explanations[index]).font(.body).lineSpacing(4)
        .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
      if index == 0 {
        note(
          "Long-press to right-click. Double-tap, hold, and move to drag. Double-tap to double-click.",
          symbol: "hand.tap")
      } else if index == 1 {
        note(
          "Your view, your perspective. Pinch out for a closer look; pinch in to see more.",
          symbol: "arrow.up.left.and.arrow.down.right")
      } else if index == 2 {
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

/// Shared native paging keeps horizontal swipes separate from each page's vertical scrolling.
private struct OnboardingPager<Content: View>: View {
  @Binding var page: Int
  let title: LocalizedStringKey
  let progressID: String
  let finish: () -> Void
  @ViewBuilder var content: (Int, CGSize) -> Content
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var palette: GuidePalette { GuidePalette(dark: colorScheme == .dark) }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        TabView(selection: $page) {
          ForEach(0..<4) { index in
            ScrollView {
              VStack(spacing: 0) {
                pageHeader(index, height: geometry.size.height)
                content(index, geometry.size)
                  .padding(.horizontal, 24).padding(.vertical, 16)
                  .frame(maxWidth: .infinity)
              }
            }
            .contentMargins(.top, 54, for: .scrollContent)
            .accessibilityIdentifier("\(progressID)-page-\(index)")
            .tag(index)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: page)
        navigation
      }
      .background(palette.background.ignoresSafeArea())
      .overlay(alignment: .top) {
        ZStack {
          Text(title).font(.headline).foregroundStyle(palette.primary)
            .accessibilityAddTraits(.isHeader)
          HStack {
            Spacer()
            Button("Skip", action: finish)
              .font(.body).foregroundStyle(palette.secondary)
              .padding(.horizontal, 14).frame(minHeight: 44)
          }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 16).frame(height: 54)
      }
      .tint(palette.accent)
    }
  }

  private func pageHeader(_ index: Int, height: CGFloat) -> some View {
    HStack {
      if height >= 450 { Text("ASTEROIDKVM").tracking(2) }
      Spacer()
      Text(String(format: "%02d / 04", index + 1)).monospacedDigit()
    }
    .font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
    .accessibilityElement(children: .ignore).accessibilityLabel("Page \(index + 1) of 4")
    .accessibilityValue(colorScheme == .dark ? "Dark appearance" : "Light appearance")
    .accessibilityIdentifier(progressID)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: change(1)
      case .decrement: change(-1)
      @unknown default: break
      }
    }
    .accessibilityHidden(index != page)
  }

  private var navigation: some View {
    VStack(spacing: 16) {
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

  private func change(_ amount: Int) { page = min(3, max(0, page + amount)) }
}

struct AppOnboardingView: View {
  let finish: () -> Void
  @State private var page = 0
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var typeSize
  private var palette: GuidePalette { GuidePalette(dark: colorScheme == .dark) }
  private let titles: [LocalizedStringKey] = [
    "Your Comet.\nWithin reach.", "A desktop.\nAt your fingertips.",
    "Small screen.\nSerious control.", "Connect once.\nCome back anytime.",
  ]
  private let subtitles: [LocalizedStringKey] = [
    "Made for Comet KVM. Designed for iPhone and iPad.",
    "Your computer, with a touch of possibility.",
    "The right tools, right where you need them.",
    "Your next connection starts here.",
  ]
  private let details: [LocalizedStringKey] = [
    "See and control the computer connected to your Comet KVM, wherever you can reach your KVM over the network.",
    "Watch live video, listen to remote audio, and use natural gestures to point, click, pan and zoom.",
    "Keep a keyboard beside your remote screen, send special keys and shortcuts, or copy text from the screen with on-device text recognition.",
    "Add your Comet’s address and sign in. Test the connection, save a profile, and choose whether to remember your password in Keychain.",
  ]
  private let footnotes: [LocalizedStringKey] = [
    "Swipe to see what’s possible", "A gesture guide is waiting at your first connection.",
    "Touch, keyboard and pointer. Your choice.",
    "You’ll need a Comet KVM and a network route to it.",
  ]

  var body: some View {
    OnboardingPager(page: $page, title: "Welcome", progressID: "welcome-progress", finish: finish) {
      index, size in
      let wide = size.width > 680 && !typeSize.isAccessibilitySize
      let edge =
        wide
        ? min(380, size.width * 0.43, max(120, size.height - 240))
        : min(300, size.width - 48, max(160, size.height * 0.32))
      Group {
        if wide {
          HStack(alignment: size.height < 450 ? .top : .center, spacing: 40) {
            hero(index, edge: edge)
            explanation(index).frame(maxWidth: 380)
          }.frame(minHeight: max(0, size.height - 210))
        } else {
          VStack(alignment: .leading, spacing: 24) {
            hero(index, edge: edge).frame(maxWidth: .infinity)
            explanation(index)
          }
        }
      }.frame(maxWidth: wide ? 920 : 520)
    }
  }

  private func explanation(_ index: Int) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(
        index == 0
          ? "BUILT FOR COMET KVM"
          : ["", "FEEL AT HOME", "DO MORE FROM HERE", "READY WHEN YOU ARE"][index]
      )
      .font(.caption.weight(.bold)).tracking(1.6).foregroundStyle(palette.teal)
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      Text(titles[index]).font(.largeTitle.weight(.bold)).tracking(-0.8)
        .foregroundStyle(palette.primary).fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      Text(subtitles[index]).font(.headline).foregroundStyle(palette.primary)
        .fixedSize(horizontal: false, vertical: true)
      Text(details[index]).font(.body).lineSpacing(3).foregroundStyle(palette.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Label(
        footnotes[index],
        systemImage: index == 0 ? "arrow.left.arrow.right" : index == 3 ? "network" : "sparkles"
      )
      .font(.footnote).foregroundStyle(palette.secondary)
      .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func hero(_ index: Int, edge: CGFloat) -> some View {
    ZStack {
      LinearGradient(
        colors: [palette.card, palette.preview], startPoint: .topLeading, endPoint: .bottomTrailing)
      if index == 1 {
        Image("GesturePointer").resizable().scaledToFit()
      } else {
        // Native artwork stays crisp at any display scale; all feature copy remains outside it.
        GeometryReader { proxy in
          let unit = proxy.size.width / 300
          ZStack {
            if index == 0 {
              Circle().stroke(palette.accent.opacity(0.14), lineWidth: 1).frame(
                width: 250, height: 250)
              Circle().trim(from: 0.05, to: 0.77).stroke(
                palette.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, lineCap: .round)
              )
              .frame(width: 220, height: 220).rotationEffect(.degrees(-25))
              Circle().fill(Color(red: 0.93, green: 0.09, blue: 0.60)).frame(width: 10, height: 10)
                .offset(x: 99, y: -75)
              desktop
              Image(systemName: "iphone").font(.system(size: 70, weight: .light))
                .foregroundStyle(palette.accent).padding(14).background(
                  palette.card, in: RoundedRectangle(cornerRadius: 24)
                )
                .rotationEffect(.degrees(9)).offset(x: 79, y: 57)
              Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(palette.teal)
                .offset(x: -91, y: -82)
            } else if index == 2 {
              VStack(spacing: 12) {
                HStack(spacing: 12) {
                  toolTile("keyboard", "Keyboard", palette.accent)
                  toolTile("command", "Shortcuts", palette.teal)
                }
                HStack(spacing: 12) {
                  toolTile("text.viewfinder", "Copy text", palette.teal)
                  toolTile("speaker.wave.2", "Audio", palette.accent)
                }
              }.padding(30)
            } else {
              VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(
                  palette.teal)
                HStack(spacing: 14) {
                  Image(systemName: "desktopcomputer").font(.system(size: 30)).foregroundStyle(
                    palette.accent)
                  VStack(alignment: .leading, spacing: 5) {
                    Text("My Comet").font(.headline).foregroundStyle(palette.primary)
                    Text("Ready to connect").font(.caption).foregroundStyle(palette.secondary)
                  }
                  Spacer(minLength: 0)
                }.padding(20).background(palette.background, in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 8) {
                  Image(systemName: "key.fill").foregroundStyle(palette.accent)
                  Text("Saved your way").foregroundStyle(palette.secondary)
                }.font(.callout)
              }.padding(28)
            }
          }
          .frame(width: 300, height: 300).scaleEffect(unit, anchor: .topLeading)
        }
      }
    }
    .frame(width: max(0, edge), height: max(0, edge))
    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: 32).strokeBorder(palette.outline, lineWidth: 1) }
    .shadow(color: palette.shadow, radius: 24, x: 0, y: 12)
    .dynamicTypeSize(.large).accessibilityHidden(true)
  }

  private var desktop: some View {
    VStack(spacing: 0) {
      VStack(spacing: 16) {
        HStack(spacing: 4) {
          ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.45)).frame(width: 4, height: 4) }
          Spacer()
        }
        Text("COMET KVM").font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(
          .white.opacity(0.85))
        Image(systemName: "cursorarrow.rays").font(.system(size: 40, weight: .light))
          .foregroundStyle(.white)
      }
      .padding(16).frame(width: 180, height: 135)
      .background(
        LinearGradient(
          colors: [
            Color(red: 0.38, green: 0.36, blue: 0.88), Color(red: 0.17, green: 0.15, blue: 0.46),
          ], startPoint: .topLeading, endPoint: .bottomTrailing),
        in: RoundedRectangle(cornerRadius: 16)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.3), lineWidth: 1)
      }
      Rectangle().fill(palette.accent).frame(width: 10, height: 16)
      Capsule().fill(palette.accent).frame(width: 64, height: 5)
    }
  }

  private func toolTile(_ symbol: String, _ title: String, _ color: Color) -> some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(color)
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(palette.primary)
    }
    .frame(maxWidth: .infinity).frame(height: 110)
    .background(palette.background, in: RoundedRectangle(cornerRadius: 22))
  }
}

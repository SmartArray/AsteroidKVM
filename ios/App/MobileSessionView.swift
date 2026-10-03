import CometCore
import CometSessionCore
import SwiftUI

private enum SessionSheet: String, Identifiable {
  case menu, type, keys, shortcuts, settings, ocr
  var id: String { rawValue }
}
struct MobileSessionView: View {
  @ObservedObject var session: SessionCore
  @EnvironmentObject private var model: MobileAppModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("onboardingVersion") private var onboardingVersion = 0
  @State private var sheet: SessionSheet?
  @State private var guide = false
  @State private var fitToken = 0
  @State private var password = ""
  @State private var nextSheet: SessionSheet?
  @State private var guideAfterDismiss = false
  @State private var enteredSession = false
  @State private var keyboardVisible = false
  @State private var keyboardAfterDismiss = false
  @State private var closing = false
  @State private var showingConnections = false
  @State private var switchingTo: ConnectionProfile?
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      MobileRemoteSurface(
        session: session,
        blocked: closing || model.switchingConnection || scenePhase != .active || sheet != nil
          || guide || onboardingVersion < 1,
        fitToken: fitToken, keyboardVisible: keyboardVisible)
      VStack(spacing: 8) {
        if model.switchingConnection {
          ProgressView("Switching connection…").padding(12).background(
            .regularMaterial, in: Capsule())
        }
        if session.phase != .connected {
          Label(
            session.phase.rawValue,
            systemImage: session.active ? "display.trianglebadge.exclamationmark" : "network"
          )
          .padding(10).background(.regularMaterial, in: Capsule())
        }
        if let message = session.message {
          HStack(alignment: .top) {
            Text(message).font(.callout)
            Button("Dismiss", systemImage: "xmark.circle.fill") { session.message = nil }
              .labelStyle(.iconOnly)
          }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(
            .horizontal)
        }
        if session.pasting {
          Label("Sending text…", systemImage: "keyboard").padding(10).background(
            .regularMaterial, in: Capsule())
        } else if let notice = session.typingNotice {
          Text(notice).font(.caption).padding(10).background(.regularMaterial, in: Capsule())
        }
        if session.ocrSelecting || session.ocrBusy {
          HStack {
            if session.ocrBusy { ProgressView() }
            Text(session.ocrBusy ? "Recognizing text…" : "Drag one finger to select text")
            Button("Cancel") {
              session.cancelOCR()
              session.ocrText = nil
            }
          }.padding().background(.regularMaterial, in: Capsule())
        }
        Spacer()
        if session.phase == .disconnected && session.pendingCertificate == nil {
          Button("Reconnect") { session.connect() }.buttonStyle(.borderedProminent).padding(
            .bottom, 80)
        }
      }.padding(.top, 8)
      if !session.ocrSelecting && !session.ocrBusy {
        FloatingMenuButton(dismissesKeyboard: keyboardVisible) {
          if keyboardVisible {
            keyboardVisible = false
          } else {
            open(.menu)
          }
        }.disabled(closing || model.switchingConnection)
      }
    }
    .onAppear {
      guard !enteredSession else { return }
      enteredSession = true
      if onboardingVersion < 1 {
        guide = true
      } else {
        Task { await model.startPendingConnection() }
      }
    }
    .onDisappear {
      keyboardVisible = false
      session.releaseCapture()
    }
    .onChange(of: session.active) { _, active in if !active { keyboardVisible = false } }
    .sheet(
      item: $sheet,
      onDismiss: {
        if let switchingTo {
          self.switchingTo = nil
          Task { await model.switchConnection(to: switchingTo) }
        } else if closing {
          // Dismiss the menu before removing the view that presents it.
          Task { await model.close() }
        } else if keyboardAfterDismiss {
          keyboardAfterDismiss = false
          keyboardVisible = session.active && session.profile.keyboardEnabled
        } else if guideAfterDismiss {
          guideAfterDismiss = false
          guide = true
        } else if let nextSheet {
          self.nextSheet = nil
          sheet = nextSheet
        } else if session.ocrText != nil {
          session.ocrText = nil
          session.cancelOCR()
        }
      }
    ) { item in
      switch item {
      case .menu: menu
      case .type: TypeSheet(session: session) { sheet = nil }
      case .keys: KeySheet(session: session, shortcuts: false) { sheet = nil }
      case .shortcuts: KeySheet(session: session, shortcuts: true) { sheet = nil }
      case .settings:
        MobileSettingsView(
          session: session, fit: { fitToken += 1 },
          guide: {
            guideAfterDismiss = true
            sheet = nil
          })
      case .ocr: OCRResultSheet(session: session) { sheet = nil }
      }
    }
    .fullScreenCover(
      isPresented: $guide,
      onDismiss: {
        Task { await model.startPendingConnection() }
      }
    ) {
      GestureOnboardingView {
        onboardingVersion = 1
        guide = false
      }
    }
    .onChange(of: session.ocrText) { _, value in if value != nil { sheet = .ocr } }
    .alert(
      "Trust this KVM certificate?",
      isPresented: Binding(
        get: { session.pendingCertificate != nil && !guide && onboardingVersion >= 1 },
        set: { if !$0 && !guide { session.pendingCertificate = nil } })
    ) {
      Button("Cancel", role: .cancel) { session.pendingCertificate = nil }
      Button("Trust and connect") { session.approveCertificate() }
    } message: {
      Text(
        "Verify this SHA-256 fingerprint against your KVM before approving:\n\n\(session.pendingCertificate ?? "")"
      )
    }
    .alert(
      "Authentication required",
      isPresented: Binding(
        get: { session.phase == .authenticating && !guide && onboardingVersion >= 1 },
        set: { if !$0 { session.phase = .disconnected } })
    ) {
      SecureField("Password", text: $password)
      Button("Cancel", role: .cancel) { session.phase = .disconnected }
      Button("Connect") {
        model.authenticate(session, password: password)
        password = ""
      }
    } message: {
      Text("Enter the password for \(session.profile.name).")
    }
  }
  private func open(_ target: SessionSheet) {
    session.releaseCapture()
    showingConnections = false
    sheet = target
  }
  private func transition(_ target: SessionSheet) {
    nextSheet = target
    sheet = nil
  }
  private var menu: some View {
    NavigationStack {
      ZStack {
        if showingConnections {
          ConnectionSwitcherView(currentID: session.id) { profile in
            guard profile.id != session.id else {
              sheet = nil
              return
            }
            switchingTo = profile
            sheet = nil
          }
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 24)))
        } else {
          List {
            HoldToDisconnect {
              closing = true
              sheet = nil
            }
            Button("Switch connection", systemImage: "rectangle.2.swap") {
              showingConnections = true
              Task { await model.capturePreview(session) }
            }.accessibilityIdentifier("switch-connection")
            Button("Keyboard", systemImage: "keyboard") {
              keyboardAfterDismiss = true
              sheet = nil
            }.disabled(!session.active || session.pasting || !session.profile.keyboardEnabled)
            Button("Type", systemImage: "square.and.pencil") { transition(.type) }.disabled(
              !session.active || session.pasting || !session.profile.keyboardEnabled)
            Button("Special keys", systemImage: "command.square") { transition(.keys) }.disabled(
              !session.active || session.pasting || !session.profile.keyboardEnabled)
            Button("Shortcuts", systemImage: "command") { transition(.shortcuts) }.disabled(
              !session.active || session.pasting || !session.profile.keyboardEnabled)
            Button("Settings", systemImage: "gearshape") { transition(.settings) }
            Button("OCR", systemImage: "text.viewfinder") {
              sheet = nil
              session.startOCR()
            }.disabled(!session.active || session.pasting)
          }.transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.2), value: showingConnections)
      .navigationTitle(showingConnections ? "Switch connection" : session.profile.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if showingConnections {
            Button("Back", systemImage: "chevron.left") { showingConnections = false }
          }
        }
        ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } }
      }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
}

private struct ConnectionSwitcherView: View {
  @EnvironmentObject private var model: MobileAppModel
  @Environment(\.colorScheme) private var colorScheme
  let currentID: UUID
  var select: (ConnectionProfile) -> Void
  private let accent = Color(red: 0.72, green: 0.53, blue: 0.19)
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Your computers").font(.title2.bold())
          Text("Pick up where you left off.").font(.subheadline).foregroundStyle(.secondary)
        }
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 150, maximum: 320), spacing: 14)], spacing: 18
        ) {
          ForEach(model.profiles) { profile in
            let current = profile.id == currentID
            Button {
              select(profile)
            } label: {
              VStack(alignment: .leading, spacing: 0) {
                ZStack {
                  LinearGradient(
                    colors: [Color(red: 0.12, green: 0.15, blue: 0.24), .black],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                  if let preview = model.previews[profile.id] {
                    Image(uiImage: preview).resizable().scaledToFit()
                  } else {
                    VStack(spacing: 8) {
                      Image(systemName: "desktopcomputer").font(.system(size: 30, weight: .light))
                      Text("Ready to connect").font(.caption2)
                    }.foregroundStyle(.white.opacity(0.65))
                  }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                  if current {
                    Label("Current", systemImage: "checkmark.circle.fill")
                      .font(.caption2.weight(.semibold)).padding(.horizontal, 9).padding(
                        .vertical, 5
                      )
                      .foregroundStyle(.white).background(.black.opacity(0.7), in: Capsule())
                      .padding(9)
                  }
                }
                VStack(alignment: .leading, spacing: 4) {
                  Text(profile.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                  Text(model.previews[profile.id] == nil ? "No preview yet" : "Last viewed")
                    .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
              }
              .background(Color(uiColor: .secondarySystemGroupedBackground))
              .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 18).strokeBorder(
                  current ? accent : Color.primary.opacity(0.08), lineWidth: current ? 2 : 1)
              )
              .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.06), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(profile.name)
            .accessibilityValue(
              (current ? "Current connection" : "Switch connection")
                + (model.previews[profile.id] == nil ? "; No preview" : "; Preview available")
            )
            .accessibilityIdentifier("switch-to-\(profile.name)")
          }
        }
      }.padding(20)
    }
    .background(Color(uiColor: .systemGroupedBackground))
    .accessibilityIdentifier("connection-switcher")
  }
}

struct FloatingMenuButton: View {
  @AppStorage("floatingCorner") private var corner = 3
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var center: CGPoint?
  @State private var dragOrigin: CGPoint?
  @GestureState private var dragging = false
  var dismissesKeyboard = false
  var accessibilityID = "connection-controls"
  var action: () -> Void
  var body: some View {
    GeometryReader { proxy in
      let position = center ?? cornerCenter(corner, in: proxy.size)
      Button(action: action) {
        Image(systemName: dismissesKeyboard ? "xmark" : "circle.grid.2x2.fill").font(.title2)
          .foregroundStyle(.white)
          .frame(width: 56, height: 56).background(
            dismissesKeyboard ? Color.red : Color(red: 0.28, green: 0.39, blue: 1), in: Circle()
          )
          .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1)).shadow(radius: 8)
      }
      .accessibilityLabel(dismissesKeyboard ? "Dismiss keyboard" : "Connection controls")
      .accessibilityHint(
        dismissesKeyboard
          ? "Hides the keyboard and restores the full remote screen."
          : "Opens the menu. Drag to move to another corner."
      )
      .accessibilityIdentifier(accessibilityID)
      .contentShape(Circle())
      .highPriorityGesture(
        DragGesture(minimumDistance: 8, coordinateSpace: .named("floating-menu"))
          .updating($dragging) { _, state, _ in
            state = true
          }.onChanged { value in
            if dragOrigin == nil { dragOrigin = position }
            guard let origin = dragOrigin else { return }
            center = bounded(
              CGPoint(
                x: origin.x + value.translation.width, y: origin.y + value.translation.height),
              in: proxy.size)
          }.onEnded { value in
            let origin = dragOrigin ?? position
            let right = origin.x + value.translation.width > proxy.size.width / 2
            let bottom = origin.y + value.translation.height > proxy.size.height / 2
            dragOrigin = nil
            snap(to: (bottom ? 2 : 0) + (right ? 1 : 0), in: proxy.size)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
          }
      )
      // Animate one absolute position; persisted corner changes cannot reapply the drag translation.
      .position(position)
      .onChange(of: dragging) { _, active in
        if !active && dragOrigin != nil {
          dragOrigin = nil
          snap(to: corner, in: proxy.size)
        }
      }
      .onChange(of: proxy.size) { _, size in
        dragOrigin = nil
        center = cornerCenter(corner, in: size)
      }
      .onChange(of: corner) { _, saved in
        if dragOrigin == nil { snap(to: saved, in: proxy.size) }
      }
      .accessibilityAction(named: "Move to next corner") {
        snap(to: (corner + 1) % 4, in: proxy.size)
      }
    }.coordinateSpace(name: "floating-menu")
  }

  private func cornerCenter(_ corner: Int, in size: CGSize) -> CGPoint {
    bounded(
      CGPoint(
        x: corner % 2 == 0 ? 38 : size.width - 38,
        y: corner < 2 ? 38 : size.height - 38), in: size)
  }

  private func bounded(_ point: CGPoint, in size: CGSize) -> CGPoint {
    let insetX = min(38, size.width / 2)
    let insetY = min(38, size.height / 2)
    return CGPoint(
      x: min(max(point.x, insetX), size.width - insetX),
      y: min(max(point.y, insetY), size.height - insetY))
  }

  private func snap(to destination: Int, in size: CGSize) {
    let target = cornerCenter(destination, in: size)
    if center != target {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { center = target }
    }
    if corner != destination { corner = destination }
  }

}

struct HoldToDisconnect: View {
  var close: () -> Void
  @State private var began: Date?
  @State private var confirm = false
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  var body: some View {
    TimelineView(.animation(minimumInterval: 0.05, paused: began == nil)) { context in
      let progress = began.map { min(1, context.date.timeIntervalSince($0)) } ?? 0
      HStack {
        ZStack {
          Circle().stroke(.red.opacity(0.2), lineWidth: 3)
          Circle().trim(from: 0, to: progress).stroke(.red, lineWidth: 3).rotationEffect(
            .degrees(-90))
          Image(systemName: "power").foregroundStyle(.red)
        }.frame(width: 32, height: 32)
        VStack(alignment: .leading) {
          Text("Close connection").foregroundStyle(.red)
          Text("Hold for one second").font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(
        Rectangle()
      )
      .onLongPressGesture(minimumDuration: 1, maximumDistance: 24) {
        guard !voiceOver else {
          confirm = true
          return
        }
        began = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        close()
      } onPressingChanged: { pressing in
        began = pressing ? Date() : nil
      }
      .accessibilityElement(children: .ignore).accessibilityLabel("Close connection")
      .accessibilityValue(began == nil ? "Requires confirmation" : "Hold in progress")
      .accessibilityAddTraits(.isButton).accessibilityAction { confirm = true }
    }
    .onDisappear { began = nil }
    .confirmationDialog("Close this connection?", isPresented: $confirm, titleVisibility: .visible)
    {
      Button("Close connection", role: .destructive) { close() }
      Button("Cancel", role: .cancel) {}
    }
  }

}

struct TypeSheet: View {
  @ObservedObject var session: SessionCore
  var dismiss: () -> Void
  @State private var text = ""
  @State private var error: String?
  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        Text("Send text to the remote computer").font(.headline)
        CommandTextEditor(text: $text).accessibilityIdentifier("type-editor")
        Text("\(text.unicodeScalars.count) / 16,384 characters").font(.caption).foregroundStyle(
          .secondary)
        if let error { Text(error).foregroundStyle(.red) }
      }.padding()
        .navigationTitle("Type").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              session.typingDraft = text
              dismiss()
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Send") {
              guard text.unicodeScalars.count <= 16_384 else {
                error = "Text can contain at most 16,384 Unicode characters."
                return
              }
              if session.submitText(text) {
                dismiss()
              } else {
                error = "Connect and wait for the current text request before sending."
              }
            }.disabled(text.isEmpty || session.pasting || !session.active)
          }
        }
    }.onAppear { text = session.typingDraft }
      .onChange(of: text) { _, value in if !session.pasting { session.typingDraft = value } }
  }
}

struct CommandTextEditor: UIViewRepresentable {
  @Binding var text: String
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.delegate = context.coordinator
    view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
    view.adjustsFontForContentSizeCategory = true
    view.autocorrectionType = .no
    view.autocapitalizationType = .none
    view.smartQuotesType = .no
    view.smartDashesType = .no
    view.smartInsertDeleteType = .no
    view.spellCheckingType = .no
    view.accessibilityLabel = "Text to send"
    DispatchQueue.main.async { view.becomeFirstResponder() }
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) {
    if view.text != text { view.text = text }
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: CommandTextEditor
    init(_ parent: CommandTextEditor) { self.parent = parent }
    func textViewDidChange(_ view: UITextView) { parent.text = view.text }
  }
}

struct KeySheet: View {
  @ObservedObject var session: SessionCore
  var shortcuts: Bool
  var dismiss: () -> Void
  @State private var sending = false
  @State private var sendTask: Task<Void, Never>?
  private var entries: [(String, [String])] {
    if shortcuts {
      return [
        ("Ctrl+Alt+Del", ["ControlLeft", "AltLeft", "Delete"]), ("Alt+Tab", ["AltLeft", "Tab"]),
      ]
        + ["C", "X", "V", "A", "Z"].map { ("Ctrl+\($0)", ["ControlLeft", "Key\($0)"]) }
        + ["C", "X", "V", "A", "Z", "S", "Q"].map { ("Command+\($0)", ["MetaLeft", "Key\($0)"]) }
        + [("Command+Tab", ["MetaLeft", "Tab"])]
    }
    return [
      "Escape", "Tab", "Enter", "Backspace", "Delete", "ArrowUp", "ArrowDown", "ArrowLeft",
      "ArrowRight", "Home", "End", "PageUp", "PageDown",
    ].map { ($0, [$0]) }
      + (1...12).map { ("F\($0)", ["F\($0)"]) }
  }
  var body: some View {
    NavigationStack {
      List(entries, id: \.0) { title, codes in
        Button(title) {
          guard let output = session.output, !sending else { return }
          sending = true
          // Finish both key-down and key-up before dismissal can change input ownership.
          sendTask = Task {
            session.shortcut(codes)
            await output.flush()
            guard !Task.isCancelled else { return }
            sending = false
            dismiss()
          }
        }.disabled(
          sending || !session.active || session.pasting || !session.profile.keyboardEnabled)
      }
      .navigationTitle(shortcuts ? "Shortcuts" : "Special keys")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) }
        ToolbarItem(placement: .confirmationAction) { if sending { ProgressView("Sending key…") } }
      }
      .onDisappear {
        sendTask?.cancel()
        sendTask = nil
      }
    }
  }
}

struct OCRResultSheet: View {
  @ObservedObject var session: SessionCore
  var dismiss: () -> Void
  var body: some View {
    NavigationStack {
      ScrollView {
        Text(
          session.ocrError
            ?? (session.ocrText?.isEmpty == false
              ? session.ocrText! : "No text found. Try selecting a larger, clearer area.")
        ).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
      }
      .navigationTitle("Recognized text")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Retry") {
            session.ocrSelecting = true
            session.ocrText = nil
            dismiss()
          }
        }
        ToolbarItemGroup(placement: .confirmationAction) {
          Button("Copy") { UIPasteboard.general.string = session.ocrText }.disabled(
            session.ocrText?.isEmpty != false)
          Button("Done") {
            session.ocrText = nil
            session.cancelOCR()
            dismiss()
          }
        }
      }
    }
  }
}

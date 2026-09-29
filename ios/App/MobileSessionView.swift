import SwiftUI
import CometCore
import CometSessionCore

private enum SessionSheet: String, Identifiable { case menu, type, keys, shortcuts, settings, ocr; var id: String { rawValue } }
struct MobileSessionView: View {
  @ObservedObject var session: SessionCore
  @EnvironmentObject private var model: MobileAppModel
  @AppStorage("onboardingVersion") private var onboardingVersion = 0
  @State private var sheet: SessionSheet?
  @State private var guide = false
  @State private var fitToken = 0
  @State private var password = ""
  @State private var nextSheet: SessionSheet?
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      MobileRemoteSurface(session: session, blocked: sheet != nil || guide || onboardingVersion < 1, fitToken: fitToken)
      VStack(spacing: 8) {
        if session.phase != .connected {
          Label(session.phase.rawValue, systemImage: session.active ? "display.trianglebadge.exclamationmark" : "network")
            .padding(10).background(.regularMaterial, in: Capsule())
        }
        if let message = session.message {
          HStack(alignment: .top) {
            Text(message).font(.callout)
            Button("Dismiss", systemImage: "xmark.circle.fill") { session.message = nil }.labelStyle(.iconOnly)
          }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal)
        }
        if session.pasting { Label("Sending text…", systemImage: "keyboard").padding(10).background(.regularMaterial, in: Capsule()) }
        else if let notice = session.typingNotice { Text(notice).font(.caption).padding(10).background(.regularMaterial, in: Capsule()) }
        if session.ocrSelecting || session.ocrBusy {
          HStack {
            if session.ocrBusy { ProgressView() }
            Text(session.ocrBusy ? "Recognizing text…" : "Drag one finger to select text")
            Button("Cancel") { session.cancelOCR(); session.ocrText = nil }
          }.padding().background(.regularMaterial, in: Capsule())
        }
        Spacer()
        if session.phase == .disconnected && session.pendingCertificate == nil {
          Button("Reconnect") { session.connect() }.buttonStyle(.borderedProminent).padding(.bottom, 80)
        }
      }.padding(.top, 8)
      if !session.ocrSelecting && !session.ocrBusy { FloatingMenuButton { open(.menu) } }
    }
    .onAppear { if onboardingVersion < 1 { guide = true } }
    .onDisappear { session.releaseCapture() }
    .sheet(item: $sheet, onDismiss: {
      if let nextSheet { self.nextSheet = nil; sheet = nextSheet }
      else if session.ocrText != nil { session.ocrText = nil; session.cancelOCR() }
    }) { item in
      switch item {
      case .menu: menu
      case .type: TypeSheet(session: session) { sheet = nil }
      case .keys: KeySheet(session: session, shortcuts: false) { sheet = nil }
      case .shortcuts: KeySheet(session: session, shortcuts: true) { sheet = nil }
      case .settings: MobileSettingsView(session: session, fit: { fitToken += 1 }, guide: { sheet = nil; guide = true })
      case .ocr: OCRResultSheet(session: session) { sheet = nil }
      }
    }
    .fullScreenCover(isPresented: $guide) { GestureOnboardingView { onboardingVersion = 1; guide = false } }
    .onChange(of: session.ocrText) { _, value in if value != nil { sheet = .ocr } }
    .alert("Trust this KVM certificate?", isPresented: Binding(get: { session.pendingCertificate != nil }, set: { if !$0 { session.pendingCertificate = nil } })) {
      Button("Cancel", role: .cancel) { session.pendingCertificate = nil }
      Button("Trust and connect") { session.approveCertificate() }
    } message: { Text("Verify this SHA-256 fingerprint against your KVM before approving:\n\n\(session.pendingCertificate ?? "")") }
    .alert("Authentication required", isPresented: Binding(get: { session.phase == .authenticating && !guide }, set: { if !$0 { session.phase = .disconnected } })) {
      SecureField("Password", text: $password)
      Button("Cancel", role: .cancel) { session.phase = .disconnected }
      Button("Connect") { session.connect(password: password); password = "" }
    } message: { Text("Enter the password for \(session.profile.name).") }
  }
  private func open(_ target: SessionSheet) { session.releaseCapture(); sheet = target }
  private func transition(_ target: SessionSheet) { nextSheet = target; sheet = nil }
  private var menu: some View {
    NavigationStack {
      List {
        HoldToDisconnect { Task { await model.close() } }
        Button("Type", systemImage: "keyboard") { transition(.type) }.disabled(!session.active || session.pasting || !session.profile.keyboardEnabled)
        Button("Special keys", systemImage: "command.square") { transition(.keys) }.disabled(!session.active || session.pasting || !session.profile.keyboardEnabled)
        Button("Shortcuts", systemImage: "command") { transition(.shortcuts) }.disabled(!session.active || session.pasting || !session.profile.keyboardEnabled)
        Button("Settings", systemImage: "gearshape") { transition(.settings) }
        Button("OCR", systemImage: "text.viewfinder") { sheet = nil; session.startOCR() }.disabled(!session.active || session.pasting)
      }.navigationTitle(session.profile.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
}

struct FloatingMenuButton: View {
  @AppStorage("floatingCorner") private var corner = 3
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @GestureState private var offset = CGSize.zero
  var action: () -> Void
  var body: some View {
    GeometryReader { proxy in
      let x: CGFloat = corner % 2 == 0 ? 38 : max(38, proxy.size.width - 38)
      let y: CGFloat = corner < 2 ? 38 : max(38, proxy.size.height - 38)
      Button(action: action) {
        Image(systemName: "circle.grid.2x2.fill").font(.title2).foregroundStyle(.white)
          .frame(width: 56, height: 56).background(Color(red: 0.28, green: 0.39, blue: 1), in: Circle())
          .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1)).shadow(radius: 8)
      }
      .accessibilityLabel("Connection controls").accessibilityHint("Opens the menu. Drag to move to another corner.")
      .accessibilityIdentifier("connection-controls")
      .position(x: x + offset.width, y: y + offset.height)
      .highPriorityGesture(DragGesture(minimumDistance: 8).updating($offset) { value, state, _ in state = value.translation }.onEnded { value in
        let right = x + value.translation.width > proxy.size.width / 2
        let bottom = y + value.translation.height > proxy.size.height / 2
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { corner = (bottom ? 2 : 0) + (right ? 1 : 0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
      })
      .accessibilityAction(named: "Move to next corner") { corner = (corner + 1) % 4 }
    }
  }
}

struct HoldToDisconnect: View {
  var close: () -> Void
  @State private var began: Date?
  @State private var hold: Task<Void, Never>?
  @State private var confirm = false
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  var body: some View {
    TimelineView(.animation(minimumInterval: 0.05, paused: began == nil)) { context in
      let progress = began.map { min(1, context.date.timeIntervalSince($0) / 2) } ?? 0
      HStack {
        ZStack {
          Circle().stroke(.red.opacity(0.2), lineWidth: 3)
          Circle().trim(from: 0, to: progress).stroke(.red, lineWidth: 3).rotationEffect(.degrees(-90))
          Image(systemName: "power").foregroundStyle(.red)
        }.frame(width: 32, height: 32)
        VStack(alignment: .leading) { Text("Close connection").foregroundStyle(.red); Text("Hold for two seconds").font(.caption).foregroundStyle(.secondary) }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
          guard !voiceOver else { return }
          if abs(value.translation.width) > 24 || abs(value.translation.height) > 24 { cancel(); return }
          guard began == nil else { return }
          began = Date()
          hold = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard began != nil else { return }
            cancel(); UINotificationFeedbackGenerator().notificationOccurred(.success); close()
          }
        }.onEnded { _ in cancel() })
        .accessibilityElement(children: .ignore).accessibilityLabel("Close connection")
        .accessibilityValue(began == nil ? "Requires confirmation" : "Hold in progress")
        .accessibilityAddTraits(.isButton).accessibilityAction { confirm = true }
        .contextMenu { Button("Confirm close connection", role: .destructive) { confirm = true } }
    }
    .onDisappear { cancel() }
    .confirmationDialog("Close this connection?", isPresented: $confirm, titleVisibility: .visible) {
      Button("Close connection", role: .destructive) { close() }
      Button("Cancel", role: .cancel) {}
    }
  }
  private func cancel() { hold?.cancel(); hold = nil; began = nil }
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
        Text("\(text.unicodeScalars.count) / 16,384 characters").font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).foregroundStyle(.red) }
      }.padding()
        .navigationTitle("Type").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.typingDraft = text; dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Send") {
              guard text.unicodeScalars.count <= 16_384 else { error = "Text can contain at most 16,384 Unicode characters."; return }
              if session.submitText(text) { dismiss() } else { error = "Connect and wait for the current text request before sending." }
            }.disabled(text.isEmpty || session.pasting || !session.active)
          }
        }
    }.onAppear { text = session.typingDraft }.onDisappear { if !session.pasting { session.typingDraft = text } }
  }
}

struct CommandTextEditor: UIViewRepresentable {
  @Binding var text: String
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let view = UITextView(); view.delegate = context.coordinator
    view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
    view.adjustsFontForContentSizeCategory = true
    view.autocorrectionType = .no; view.autocapitalizationType = .none
    view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no; view.spellCheckingType = .no
    view.accessibilityLabel = "Text to send"
    DispatchQueue.main.async { view.becomeFirstResponder() }
    return view
  }
  func updateUIView(_ view: UITextView, context: Context) { if view.text != text { view.text = text } }
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
  private var entries: [(String,[String])] {
    if shortcuts {
      return [("Ctrl+Alt+Del",["ControlLeft","AltLeft","Delete"]), ("Alt+Tab",["AltLeft","Tab"])]
        + ["C","X","V","A","Z"].map { ("Ctrl+\($0)",["ControlLeft","Key\($0)"]) }
        + ["C","X","V","A","Z","S","Q"].map { ("Command+\($0)",["MetaLeft","Key\($0)"]) }
        + [("Command+Tab",["MetaLeft","Tab"])]
    }
    return ["Escape","Tab","Enter","Backspace","Delete","ArrowUp","ArrowDown","ArrowLeft","ArrowRight","Home","End","PageUp","PageDown"].map { ($0,[$0]) }
      + (1...12).map { ("F\($0)",["F\($0)"]) }
  }
  var body: some View {
    NavigationStack {
      List(entries, id: \.0) { title, codes in Button(title) { session.shortcut(codes); dismiss() }.disabled(!session.active || session.pasting || !session.profile.keyboardEnabled) }
        .navigationTitle(shortcuts ? "Shortcuts" : "Special keys")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) } }
    }
  }
}

struct OCRResultSheet: View {
  @ObservedObject var session: SessionCore
  var dismiss: () -> Void
  var body: some View {
    NavigationStack {
      ScrollView { Text(session.ocrText?.isEmpty == false ? session.ocrText! : "No text found. Try selecting a larger, clearer area.").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
        .navigationTitle("Recognized text")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Retry") { session.ocrSelecting = true; session.ocrText = nil; dismiss() } }
          ToolbarItemGroup(placement: .confirmationAction) {
            Button("Copy") { UIPasteboard.general.string = session.ocrText }.disabled(session.ocrText?.isEmpty != false)
            Button("Done") { session.ocrText = nil; session.cancelOCR(); dismiss() }
          }
        }
    }
  }
}

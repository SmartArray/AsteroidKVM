import CometCore
import CometSession
import SwiftUI

struct PastePreviewView: View {
  @ObservedObject var session: SessionController
  let preview: PastePreview

  private var options: PasteOptions { session.profile.pasteOptions ?? PasteOptions() }
  private var previewText: String {
    String(String.UnicodeScalarView(preview.text.unicodeScalars.prefix(PastePreparation.limit)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Paste to \(session.profile.name)", systemImage: "doc.on.clipboard")
        .font(.headline)
      GeometryReader { geometry in
        ScrollView([.horizontal, .vertical]) {
          Text(previewText)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
            .padding(10)
            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            .accessibilityIdentifier("paste-preview-text")
        }
      }
      .frame(height: 220)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
      Text("\(preview.text.unicodeScalars.count) characters · Read-only clipboard preview")
        .font(.caption).foregroundStyle(.secondary)
      Picker("Target keyboard layout", selection: Binding(
        get: { session.profile.keymap },
        set: { value in session.updateProfile { $0.keymap = value } }
      )) {
        if !session.state.availableKeymaps.contains(session.profile.keymap) {
          Text("\(session.profile.keymap.uppercased()) (unavailable)").tag(session.profile.keymap)
        }
        ForEach(session.state.availableKeymaps, id: \.self) { Text($0.uppercased()).tag($0) }
      }.accessibilityIdentifier("paste-preview-layout")
      Toggle("Dead-Key handler", isOn: Binding(
        get: { options.handleDeadKeys },
        set: { value in setOptions { $0.handleDeadKeys = value } }
      )).accessibilityIdentifier("paste-preview-dead-keys")
      Text("Finish literal accent keys with Space using the target layout. Choose the layout configured on the remote computer.")
        .font(.caption).foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 12) {
        Toggle("Fast mode", isOn: Binding(
          get: { options.fastMode },
          set: { value in setOptions { $0.fastMode = value } }
        )).fixedSize().accessibilityIdentifier("paste-preview-fast-mode")
        Label("Comet KVM can produce invalid key states when many modifier keys (Shift, Ctrl, Alt, etc.) are involved.",
          systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
      if let error = session.pastePreviewError {
        Text(error).font(.caption).foregroundStyle(.red)
          .accessibilityIdentifier("paste-preview-error")
      }
      HStack {
        Text("Layout and options are remembered for this connection.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", role: .cancel) { session.cancelPastePreview() }
          .keyboardShortcut(.cancelAction).accessibilityIdentifier("paste-preview-cancel")
        Button("Submit") { session.submitPastePreview(id: preview.id) }
          .keyboardShortcut(.defaultAction)
          .disabled(!session.active || session.pasting || session.mcpInputLocked || session.pastePreviewError != nil)
          .accessibilityIdentifier("paste-preview-submit")
      }
    }
    .padding(20).frame(width: 620)
  }

  private func setOptions(_ change: (inout PasteOptions) -> Void) {
    var updated = options
    change(&updated)
    session.updateProfile { $0.pasteOptions = updated }
  }
}

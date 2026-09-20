// Present opt-in transcription controls, a rolling caption strip, and a session-owned history window.
import CometCore
import CometSession
import SwiftUI

struct TranscriptionPopover: View {
  @ObservedObject var controller: TranscriptionController
  let setEnabled: (Bool) -> Void
  let openHistory: () -> Void
  let openSettings: () -> Void

  // Disclose where audio goes at the control that starts transmission, including its playback-capture scope.
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Live Transcription", systemImage: "captions.bubble").font(.headline)
      Toggle("Transcribe remote audio", isOn: Binding(get: { controller.active }, set: setEnabled))
        .accessibilityIdentifier("transcription-toggle")
      Text(controller.status).font(.caption).foregroundStyle(.secondary)
      Text("Sends AsteroidKVM playback audio to OpenAI. API billing applies. Keep only one remote session connected and playback unmuted.")
        .font(.caption).foregroundStyle(.secondary)
      Divider()
      Button("Show Session Transcript…", action: openHistory)
        .accessibilityIdentifier("transcription-history-link")
      Button("Transcription Settings…", action: openSettings)
        .accessibilityIdentifier("transcription-settings-link")
    }.padding(18).frame(width: 330)
  }
}

struct TranscriptStrip: View {
  @ObservedObject var controller: TranscriptionController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let open: () -> Void

  // Keep only a short rolling tail in the status strip; the complete retained transcript stays in its own window.
  private var tail: String {
    String(controller.transcript.segments.suffix(4).map(\.text).joined(separator: " ").suffix(600))
      .replacingOccurrences(of: "\n", with: " ")
  }
  var body: some View {
    if controller.active || !controller.transcript.segments.isEmpty {
      Button(action: open) {
        HStack(spacing: 10) {
          Image(systemName: "captions.bubble.fill")
            .foregroundStyle(controller.active ? Color.purple : .secondary)
          ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 0) {
                Text(tail.isEmpty ? controller.status : tail).fixedSize()
                Color.clear.frame(width: 1, height: 1).id("latest")
              }
            }
            .allowsHitTesting(false)
            .frame(height: 20)
            .onChange(of: tail) { _, _ in
              withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo("latest", anchor: .trailing)
              }
            }
            .onAppear { proxy.scrollTo("latest", anchor: .trailing) }
          }
          Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
        }.font(.callout).padding(.horizontal, 12).padding(.vertical, 9)
          .contentShape(Rectangle())
      }.buttonStyle(.plain).background(.bar)
        .help("Open the complete session transcript")
        .accessibilityLabel("Session transcript: " + (tail.isEmpty ? controller.status : tail))
        .accessibilityIdentifier("transcript-strip")
      Divider()
    }
  }
}

struct TranscriptWindow: View {
  @ObservedObject var controller: TranscriptionController
  let name: String

  // Plain selectable text avoids interpreting remote speech as executable links or formatting instructions.
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading) {
          Text(name).font(.headline)
          Text(controller.status).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Clear", role: .destructive) { controller.clear() }
          .help("Stop transcription and erase this session’s transcript history")
          .accessibilityIdentifier("transcript-clear")
      }.padding(16)
      Divider()
      ScrollViewReader { _ in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            if controller.transcript.segments.isEmpty {
              Text("No transcript yet. Start transcription from the remote display toolbar.")
                .foregroundStyle(.secondary).accessibilityIdentifier("transcript-empty")
            }
            ForEach(controller.transcript.segments) { segment in
              if !segment.text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                  Text(segment.time, style: .time).font(.caption).foregroundStyle(.secondary)
                  Text(segment.text).textSelection(.enabled)
                    .foregroundStyle(segment.complete ? Color.primary : .secondary)
                }
              }
            }
            Color.clear.frame(height: 1).id("latest")
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
      }
      Text("History stays in memory for this session. Clear also stops transcription.")
        .font(.caption).foregroundStyle(.secondary).padding(12)
    }.frame(minWidth: 480, minHeight: 300)
  }
}

struct TranscriptionSettingsView: View {
  @EnvironmentObject var model: AppModel
  @AppStorage("transcriptionLanguage") private var language = ""
  @State private var key = ""
  @State private var saved = false
  @State private var message: String?

  // Never load a saved key into the text field or UserDefaults; changing credentials stops active transmissions.
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Live captions for remote audio").font(.headline)
      Text("Audio is sent to OpenAI using your API account. API usage is billed separately from Codex or ChatGPT. Transcription starts only when you enable it in the remote toolbar.")
      LabeledContent("Model", value: "gpt-live-transcribe")
      SecureField(saved ? "Replace saved OpenAI API key" : "OpenAI API key", text: $key)
        .textFieldStyle(.roundedBorder).accessibilityIdentifier("transcription-api-key")
      HStack {
        Button("Save in Keychain") {
          stopAll()
          do { try TranscriptionCredentials.save(key); key = ""; saved = true; message = "API key saved." }
          catch { message = "Could not save the API key in Keychain." }
        }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Remove API Key", role: .destructive) {
          stopAll()
          do { try TranscriptionCredentials.remove(); saved = false; key = ""; message = "API key removed." }
          catch { message = "Could not remove the API key from Keychain." }
        }.disabled(!saved)
      }
      if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
      Picker("Spoken language", selection: $language) {
        Text("Automatic").tag("")
        ForEach(["en", "de", "fr", "es", "it", "pt", "nl", "ja", "ko", "zh"], id: \.self) {
          Text(Locale.current.localizedString(forLanguageCode: $0) ?? $0).tag($0)
        }
      }.onChange(of: language) { _, _ in stopAll() }
      Divider()
      Text("Allow AsteroidKVM in macOS Screen & System Audio Recording when prompted. Only this app’s playback is captured; your microphone and other apps are excluded. Audio continues playing normally.")
      Text("Keep one remote session connected and Mute remote playback off. Connecting another session, disconnecting, sleeping, or changing these settings stops transcription. Click the caption strip to read or clear the full session history.")
        .foregroundStyle(.secondary)
    }.onAppear {
      do { saved = try TranscriptionCredentials.read()?.isEmpty == false }
      catch { message = "Could not access Keychain." }
    }
  }

  // Require a deliberate restart after changes so existing provider sessions never retain old settings silently.
  private func stopAll() {
    model.sessions.values.forEach { $0.transcription.stop(reason: "Settings changed · restart transcription") }
  }
}

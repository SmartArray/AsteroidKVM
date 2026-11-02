import CometCore
import CometMedia
import CometSession
import SwiftUI

struct AudioSettingsView: View {
  @ObservedObject var session: SessionController
  @ObservedObject private var devices = AudioOutputDevices.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Picker("Output device", selection: Binding(
        get: { session.profile.audioOutputDeviceUID ?? "" },
        set: { uid in session.updateProfile { $0.audioOutputDeviceUID = uid.isEmpty ? nil : uid } }
      )) {
        Text("System Default").tag("")
        ForEach(devices.devices) { device in Text(device.name).tag(device.id) }
        if let uid = session.profile.audioOutputDeviceUID, !devices.devices.contains(where: { $0.id == uid }) {
          Text("Saved output (unavailable)").tag(uid)
        }
      }.accessibilityIdentifier("audio-output-device")
      Text("Includes output devices configured in Audio MIDI Setup. Saved for this connection.")
        .font(.caption).foregroundStyle(.secondary)
      if let message = session.audioOutputMessage {
        Text(message).font(.caption).foregroundStyle(.orange)
      }
      Toggle("Mute remote playback", isOn: Binding(
        get: { session.profile.muted }, set: { value in session.updateProfile { $0.muted = value } }
      )).accessibilityIdentifier("audio-mute")
      Toggle("Forward this Mac’s microphone", isOn: Binding(
        get: { session.microphone }, set: { session.setMicrophone($0) }
      )).disabled(!session.active || session.mediaFeatures["mic"].bool != true)
      if session.mediaFeatures["mic"].bool != true {
        Text("Microphone forwarding is not advertised by the media service.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      AudioRecordingButton(session: session, controller: session.audioRecording)
      AudioRecordingDetails(controller: session.audioRecording)
    }.onAppear { devices.refresh() }
  }
}

struct AudioNotificationSettingsView: View {
  @ObservedObject var session: SessionController
  @State private var draft = AudioNotificationPreferences()
  @StateObject private var connectionTest = AudioNotificationTestController()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Toggle("Notify when audio is detected", isOn: $draft.enabled)
        .accessibilityIdentifier("audio-notifications-enabled")
      Text("Send a notification and a screenshot of this KVM to your webhook, including while playback is muted. The KVM must be connected with live video. Use the blue Audio Notification Webhook button in the status bar to pause or resume delivery.")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text("Webhook URL")
        TextField("Webhook URL", text: $draft.endpoint, prompt: Text("https://example.com/webhook"))
          .textFieldStyle(.roundedBorder).accessibilityIdentifier("audio-webhook-url")
        Text("Paste the complete receiver URL, including its secret token (?token=…).")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !draft.endpoint.isEmpty && draft.endpointURL == nil {
        Text("Enter an HTTP or HTTPS URL without a username, password, or fragment.")
          .font(.caption).foregroundStyle(.orange)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("KVM alias (optional)")
        TextField("KVM alias", text: $draft.alias, prompt: Text(session.profile.name))
          .textFieldStyle(.roundedBorder).accessibilityIdentifier("audio-webhook-alias")
      }
      Text("Every notification includes the connection’s ID and name, plus this alias.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button {
          var profile = session.profile
          profile.audioNotifications = draft
          connectionTest.sendTest(profile: profile)
        } label: {
          Label("Send Test Notification", systemImage: "paperplane")
        }
        .disabled(draft.endpointURL == nil || connectionTest.sending)
        .accessibilityIdentifier("audio-webhook-test")
        if connectionTest.sending {
          ProgressView().controlSize(.small)
          Text("Sending test…").font(.caption).foregroundStyle(.secondary)
        }
      }
      Text("Tests the URL and secret above with a sample image, even when disconnected. You can test before saving or enabling notifications.")
        .font(.caption).foregroundStyle(.secondary)
      if let result = connectionTest.result {
        Label(result, systemImage: connectionTest.failed ? "exclamationmark.triangle" : "checkmark.circle")
          .font(.caption).foregroundStyle(connectionTest.failed ? Color.orange : Color.green)
          .accessibilityIdentifier("audio-webhook-test-result")
      }
      HStack {
        Text("Cooldown")
        TextField("Seconds", value: $draft.cooldownSeconds, format: .number.precision(.fractionLength(0)))
          .textFieldStyle(.roundedBorder).frame(width: 90)
          .accessibilityIdentifier("audio-webhook-cooldown")
        Text("seconds").foregroundStyle(.secondary)
      }
      Text("At most one notification per cooldown, including during continuous audio. Default: 30 seconds; range: 1–86,400 seconds.")
        .font(.caption).foregroundStyle(.secondary)
      VStack(alignment: .leading) {
        HStack {
          Text("Detection threshold")
          Spacer()
          Text("\(Int(draft.threshold)) dBFS").monospacedDigit().foregroundStyle(.secondary)
        }
        Slider(value: $draft.thresholdDecibels, in: -60 ... -10, step: 1)
        Text("Lower values detect quieter sounds. Raise the threshold to ignore background noise.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button("Save Notification Settings") {
        draft.cooldownSeconds = draft.cooldown
        draft.thresholdDecibels = draft.threshold
        draft.endpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.alias = draft.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        session.updateProfile { $0.audioNotifications = draft }
      }
      .buttonStyle(.borderedProminent)
      .disabled((draft.enabled && draft.endpointURL == nil) || !draft.cooldownSeconds.isFinite
        || !(1...86400).contains(draft.cooldownSeconds))
      .accessibilityIdentifier("audio-notifications-save")
      AudioNotificationStatusView(controller: session.audioNotifications)
      Text("Webhooks receive an HTTP POST with JSON and a base64 JPEG screenshot. Use an endpoint that accepts this payload.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear { draft = session.profile.audioNotifications ?? AudioNotificationPreferences() }
    .onChange(of: session.profile.audioNotifications) { _, preferences in
      draft = preferences ?? AudioNotificationPreferences()
    }
    .onChange(of: draft) { _, _ in connectionTest.reset() }
    .onChange(of: session.profile.id) { _, _ in connectionTest.reset() }
    .onDisappear { connectionTest.reset() }
  }
}

private struct AudioNotificationStatusView: View {
  @ObservedObject var controller: AudioNotificationController
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      LabeledContent("Status", value: controller.status)
      if let date = controller.lastDelivery {
        LabeledContent("Last delivered", value: date.formatted(date: .abbreviated, time: .standard))
      }
      if let error = controller.lastError { Text(error).foregroundStyle(.orange) }
    }.font(.caption)
  }
}

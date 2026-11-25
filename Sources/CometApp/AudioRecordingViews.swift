import CometSession
import SwiftUI

struct AudioRecordingButton: View {
  @ObservedObject var session: SessionController
  @ObservedObject var controller: AudioRecordingController

  var body: some View {
    Button(action: session.toggleAudioRecording) {
      Label(controller.isRecording ? "Stop Recording" : controller.isSaving ? "Saving Recording…" : "Record Audio",
        systemImage: controller.isRecording ? "stop.circle.fill" : "record.circle")
    }
    .foregroundStyle(controller.isRecording ? Color.red : Color.primary)
    .disabled(controller.isSaving || (!controller.isRecording && !session.active))
    .help(controller.isRecording
      ? "Stop recording and save the WAV file"
      : "Record received KVM audio, including while playback is muted")
    .accessibilityValue(controller.isRecording ? "Recording" : controller.isSaving ? "Saving" : "Stopped")
    .accessibilityIdentifier("audio-recording-toggle")
  }
}

struct AudioRecordingDetails: View {
  @ObservedObject var controller: AudioRecordingController

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Record this KVM’s received audio as WAV, including while playback is muted. Files are saved in Downloads/AsteroidKVM Recordings with the connection name and recording start time.")
        .font(.caption).foregroundStyle(.secondary)
      if let url = controller.lastSavedURL {
        Text(url.lastPathComponent).font(.caption).textSelection(.enabled)
          .accessibilityIdentifier("audio-recording-filename")
        Button("Show Recording in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          .accessibilityIdentifier("audio-recording-reveal")
      }
      if let error = controller.lastError {
        Text(error).font(.caption).foregroundStyle(.orange)
          .accessibilityIdentifier("audio-recording-error")
      }
    }
  }
}

struct AudioRecordingStatus: View {
  @ObservedObject var session: SessionController
  @ObservedObject var controller: AudioRecordingController

  var body: some View {
    if controller.isRecording, let startedAt = controller.startedAt {
      Button {
        session.releaseCapture()
        session.stopAudioRecording()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "stop.circle.fill")
          Text("Recording")
          Text(startedAt, style: .timer).monospacedDigit()
        }
      }
      .buttonStyle(.plain).foregroundStyle(.red)
      .help("Stop recording and save the WAV file")
      .accessibilityIdentifier("audio-recording-status")
    } else if controller.isSaving {
      Text("Saving recording…")
    } else if controller.lastError != nil {
      Label("Recording error · see Audio", systemImage: "exclamationmark.circle")
        .foregroundStyle(.orange)
    }
  }
}

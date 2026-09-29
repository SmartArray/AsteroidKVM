import CometCore
import CometSession
import SwiftUI

struct PerceptionSettingsView: View {
  @ObservedObject private var service = LocalPerception.shared
  @State private var draft = PerceptionSettings()
  @State private var token = ""
  @State private var error: String?
  @State private var checking = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        "Parse KVM screens locally. All connections share the parser; each device keeps its own element IDs and cache."
      )
      Toggle("Enable local UI parsing", isOn: $draft.enabled).accessibilityIdentifier(
        "perception-enable")
      TextField("Service host", text: $draft.host)
      SecureField("Service token (leave blank to keep saved token)", text: $token)
      TextField("Service port", value: $draft.port, format: .number.grouping(.never))
      Picker("Preferred inference device", selection: $draft.preferredDevice) {
        Text("Automatic (prefer MPS)").tag("auto")
        Text("Apple GPU / MPS").tag("mps")
        Text("CPU").tag("cpu")
      }
      Text(
        "Models load once at startup. Save your preference, then stop and start the service to change CPU/MPS selection. CPU fallback is reported below."
      )
      .font(.caption).foregroundStyle(.secondary)
      Stepper(
        "Request timeout: \(Int(draft.requestTimeout)) seconds", value: $draft.requestTimeout,
        in: 1...110)
      VStack(alignment: .leading) {
        Text("Cache change threshold: \(draft.cacheThreshold * 100, specifier: "%.1f")% per tile")
        Slider(value: $draft.cacheThreshold, in: 0...0.05, step: 0.001)
        Text(
          "Lower values reparse more often. Element actions always use a stricter threshold of at most 1% changed pixels per tile."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading) {
        Text("Minimum detection confidence: \(draft.minimumConfidence, specifier: "%.2f")")
        Slider(value: $draft.minimumConfidence, in: 0...1, step: 0.01)
      }
      Stepper(
        "Settle after focusing a text field: \(draft.settlingMilliseconds) ms",
        value: $draft.settlingMilliseconds, in: 0...2000, step: 50)
      Toggle("Log performance diagnostics", isOn: $draft.debugLogging)
      Text(
        "Performance logs contain timings, cache status and device selection, never screenshots or detected text. Inspect element overlays from the remote window’s Diagnostics."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Save and Check Connection") {
          do {
            try service.save(
              draft, token: token.isEmpty ? nil : token)
            token = ""
            error = nil
            checking = true
            Task {
              await service.checkHealth()
              checking = false
            }
          } catch { self.error = error.localizedDescription }
        }.disabled(checking)
        Button("Reconnect") {
          checking = true
          Task {
            await service.checkHealth()
            checking = false
          }
        }.disabled(checking || !service.settings.enabled)
        if checking { ProgressView().controlSize(.small) }
      }
      Text(service.status).textSelection(.enabled)
      if let health = service.health {
        LabeledContent("Model", value: health.model)
        LabeledContent("Version", value: health.version ?? "Not loaded")
        LabeledContent("CPU fallback", value: health.cpuFallback ? "Active" : "No")
      }
      if let error { Text(error).foregroundStyle(.red) }
      Text(
        "Start the local parser service before checking the connection. Raw screenshots and keyboard/mouse tools remain available if parsing is disabled."
      )
      .font(.caption).foregroundStyle(.secondary)
    }.onAppear { draft = service.settings }
  }
}

// Both entry points use one explicit snapshot action; video updates never trigger parsing.
struct PerceptionDebugSettingsView: View {
  @ObservedObject var session: SessionController

  var body: some View {
    if session.phase == .connected {
      PerceptionSnapshotView(server: session.mcpServer, imageHeight: 260)
    } else {
      Text("Connect this KVM to capture a debug image.").foregroundStyle(.secondary)
    }
  }
}

struct PerceptionDiagnosticsView: View {
  @ObservedObject var server: DeviceMCPServer
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("UI Parsing Debug").font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }
      }
      PerceptionSnapshotView(server: server, imageHeight: 400)
    }.padding(20).frame(width: 1000, height: 800)
  }
}

private struct PerceptionSnapshotView: View {
  @ObservedObject var server: DeviceMCPServer
  let imageHeight: CGFloat
  @State private var captureTask: Task<Void, Never>?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "Capture one KVM image and draw every detected bounding box. Hover over a box to inspect it. The image stays frozen until you capture again."
      )
      .foregroundStyle(.secondary)
      Button("Capture and Draw Bounding Boxes") {
        error = nil
        server.clearPerceptionDiagnostics()
        captureTask = Task { @MainActor in
          defer { captureTask = nil }
          do { try await server.inspectPerception() } catch is CancellationError {} catch {
            self.error = error.localizedDescription
          }
        }
      }
      .disabled(captureTask != nil)
      .accessibilityIdentifier("perception-debug-capture")
      if captureTask != nil { ProgressView("Parsing captured image locally…") }
      if let error { Text(error).foregroundStyle(.red) }
      if let screen = server.diagnosticScreen, let data = server.diagnosticImage,
        let image = NSImage(data: data)
      {
        PerceptionBoundingBoxesView(screen: screen, image: image, imageHeight: imageHeight)
          .id(screen.frameID)
        Text(
          "Captured \(Date(timeIntervalSince1970: screen.timestamp).formatted(date: .omitted, time: .standard)) · \(screen.width) × \(screen.height) · \(screen.elements.count) elements"
        )
        .font(.caption).accessibilityIdentifier("perception-debug-snapshot")
        Text(
          "Green: interactive · Orange: other · Cyan: hovered. Boxes use the configured minimum confidence."
        )
        .font(.caption).foregroundStyle(.secondary)
      } else if captureTask == nil {
        Text(
          "No snapshot yet. Enable Local UI Parsing and start its service, then capture a frame."
        )
        .foregroundStyle(.secondary)
      }
    }
    .onDisappear {
      captureTask?.cancel()
      captureTask = nil
      server.clearPerceptionDiagnostics()
    }
  }
}

private struct PerceptionBoundingBoxesView: View {
  let screen: ParsedScreen
  let image: NSImage
  let imageHeight: CGFloat
  @State private var hoveredID: Int?
  @State private var inspectedID: Int?

  private var hoveredElement: UIElement? {
    screen.elements.first { $0.id == hoveredID }
  }

  private var inspectedElement: UIElement? {
    screen.elements.first { $0.id == inspectedID }
  }

  private func box(_ element: UIElement, scale: CGFloat = 1) -> CGRect {
    let b = element.bboxPx
    return CGRect(
      x: CGFloat(b[0]) * scale, y: CGFloat(b[1]) * scale,
      width: CGFloat(b[2] - b[0]) * scale, height: CGFloat(b[3] - b[1]) * scale)
  }

  private func details(_ element: UIElement) -> String {
    var lines = [
      "ID \(element.id) · \(element.type.rawValue)",
      "Interactive: \(element.interactive ? "Yes" : "No") · Confidence: \(element.confidence.map { String(format: "%.1f%%", $0 * 100) } ?? "Unavailable")",
    ]
    if let text = element.text { lines.append("Text: \(text)") }
    if let description = element.description { lines.append("Description: \(description)") }
    if let label = element.label { lines.append("Label: \(label)") }
    lines.append("Box (pixels): \(element.bboxPx)")
    lines.append(
      "Box (normalized): \(element.bboxNorm.map { String(format: "%.4f", $0) }.joined(separator: ", "))"
    )
    lines.append("Click point: \(element.clickPoint)")
    if let parent = element.parentID { lines.append("Parent ID: \(parent)") }
    if let labelFor = element.labelFor { lines.append("Label for ID: \(labelFor)") }
    if let children = element.children, !children.isEmpty { lines.append("Child IDs: \(children)") }
    return lines.joined(separator: "\n")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      GeometryReader { geometry in
        let scale = min(
          geometry.size.width / CGFloat(screen.width),
          geometry.size.height / CGFloat(screen.height))
        ZStack(alignment: .topLeading) {
          Image(nsImage: image).resizable()
          Canvas { context, _ in
            // Draw all boxes first, then highlight the hit target above overlapping containers.
            for element in screen.elements {
              context.stroke(
                Path(box(element, scale: scale)),
                with: .color(element.interactive ? .green : .orange), lineWidth: 1)
            }
            if let element = hoveredElement {
              context.stroke(Path(box(element, scale: scale)), with: .color(.cyan), lineWidth: 3)
            }
          }.allowsHitTesting(false)
        }
        .frame(width: CGFloat(screen.width) * scale, height: CGFloat(screen.height) * scale)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let point):
            let source = CGPoint(x: point.x / scale, y: point.y / scale)
            // Prefer a border hit, then the smallest containing box, so nested controls remain reachable.
            let candidates = screen.elements.filter { box($0).contains(source) }
            let borders = candidates.filter {
              !box($0).insetBy(dx: 3 / scale, dy: 3 / scale).contains(source)
            }
            hoveredID =
              (borders.isEmpty ? candidates : borders).min {
                let a = box($0)
                let b = box($1)
                return a.width * a.height < b.width * b.height
              }?.id
            if let hoveredID { inspectedID = hoveredID }
          case .ended: hoveredID = nil
          }
        }
        .help(
          hoveredElement.map(details) ?? "Hover over a bounding box to inspect its information."
        )
        .accessibilityLabel("Frozen KVM image with \(screen.elements.count) bounding boxes")
      }.frame(height: imageHeight)
      ScrollView {
        Text(
          inspectedElement.map(details)
            ?? (screen.elements.isEmpty
              ? "No elements detected in this snapshot."
              : "Hover over a bounding box to see its type, text, icon description, confidence and coordinates.")
        )
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
      }
      .frame(height: 160)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityIdentifier("perception-debug-element-info")
    }
  }
}

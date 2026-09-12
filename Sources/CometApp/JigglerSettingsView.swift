// Edit the firmware's advertised interval and daily schedule using native time controls.
import CometCore
import CometSession
import SwiftUI

struct JigglerSettingsView: View {
  @ObservedObject var session: SessionController
  @State private var interval = 20
  @State private var editingSchedule = false

  // Keep drafts local until Apply so editing a number cannot send intermediate device mutations.
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if session.state.hid["jiggler"]["interval"].number != nil {
        HStack {
          TextField(
            "Jiggler interval (seconds)", value: $interval, format: .number.grouping(.never))
          Button("Apply") { session.setHID("jiggler_interval", value: String(interval)) }
            .disabled(
              !session.active || !(1...3600).contains(interval)
                || interval == Int(session.state.hid["jiggler"]["interval"].number ?? 20))
        }
        Text("1–3,600 seconds between movements while idle.").font(.caption).foregroundStyle(
          .secondary)
      }
      if session.state.hid["jiggler"].object["schedule"] != nil {
        Button("Daily Jiggler Schedule…") { editingSchedule = true }
        Text("An active schedule can keep the jiggler running even when you turn it off manually.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .disabled(!session.active)
    .onAppear { interval = Int(session.state.hid["jiggler"]["interval"].number ?? 20) }
    .onChange(of: session.state.hid["jiggler"]["interval"]) { _, value in
      interval = Int(value.number ?? 20)
    }
    .sheet(isPresented: $editingSchedule) {
      JigglerScheduleEditor(
        session: session, values: session.state.hid["jiggler"]["schedule"].array)
    }
  }
}

// Time-only dates provide native editing while the wire contract remains device-local HH:MM.
private struct JigglerPeriod: Identifiable {
  let id = UUID()
  var start: Date
  var end: Date

  // Anchor times to one calendar day because only hours and minutes are sent to the appliance.
  static func date(_ text: String) -> Date {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    return Calendar.current.date(
      bySettingHour: parts.first ?? 9, minute: parts.last ?? 0, second: 0, of: Date()) ?? Date()
  }

  // Fixed-width numeric formatting avoids locale-specific separators in the API payload.
  var json: JSONValue {

    // Encode hours and minutes with the fixed separator required by the daemon.
    func time(_ date: Date) -> String {
      let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
      return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
    return .object(["start": .string(time(start)), "end": .string(time(end))])
  }
}

private struct JigglerScheduleEditor: View {
  @ObservedObject var session: SessionController
  @Environment(\.dismiss) private var dismiss
  @State private var periods: [JigglerPeriod]

  // Snapshot the current schedule when opening; Cancel leaves the device untouched.
  init(session: SessionController, values: [JSONValue]) {
    self.session = session
    _periods = State(
      initialValue: values.map {
        JigglerPeriod(
          start: JigglerPeriod.date($0["start"].text), end: JigglerPeriod.date($0["end"].text))
      })
  }

  // An empty schedule disables timed activation; overnight ranges are supported by the daemon.
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Daily Jiggler Schedule").font(.title2.bold())
      Text(
        "Times use the Comet’s local clock. A range can cross midnight. Remove all ranges to disable scheduled activation."
      ).foregroundStyle(.secondary)
      ScrollView {
        ForEach($periods) { $period in
          HStack {
            DatePicker("From", selection: $period.start, displayedComponents: .hourAndMinute)
            DatePicker("Until", selection: $period.end, displayedComponents: .hourAndMinute)
            Button("Remove", systemImage: "minus.circle") {
              periods.removeAll { $0.id == period.id }
            }.labelStyle(.iconOnly)
          }
        }
      }.frame(minHeight: 80, maxHeight: 240)
      Button("Add Time Range", systemImage: "plus") {
        periods.append(
          JigglerPeriod(start: JigglerPeriod.date("09:00"), end: JigglerPeriod.date("17:00")))
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          session.setJigglerSchedule(periods.map(\.json))
          dismiss()
        }.keyboardShortcut(.defaultAction).disabled(!session.active)
      }
    }.padding(24).frame(width: 540)
  }
}

# Build a native Swift app for GL.iNet Comet

Build a beautiful, fast, reliable macOS app for controlling machines connected to **GL.iNet Comet / GLKVM devices**.

The app should feel like a carefully designed Mac application: clean windows, clear menus, thoughtful keyboard shortcuts, native settings, and excellent fullscreen behavior.

Use **Swift and SwiftUI**, with **AppKit where needed for precise keyboard handling, window management, and rendering**. Use native WebRTC and Metal for video.

If an existing project such as `./Overlook` is available, inspect it first. Reuse working API and protocol code where appropriate. Preserve useful functionality while improving the architecture and interface.

## 1. Product priorities

Prioritize these in order:

1. Excellent fullscreen and reliable input.
2. Low-latency, smooth video.
3. Clean, native macOS UI.
4. Reliable management of multiple connections.
5. Complete controls for the features supported by the connected Comet.

Build a working application, including the real network integration. Every visible control should either work or clearly explain why it is unavailable.

Keep implementation details out of the main interface. Technical information belongs in diagnostics, except where users need it to understand a limitation.

## 2. Design and navigation

Use native macOS conventions:

- Standard window controls and window behavior.
- Native typography, SF Symbols, and consistent spacing.
- Light and dark appearance.
- A restrained accent color.
- Clear hover, focus, selected, and disabled states.
- Accessible labels and keyboard navigation.
- Native sheets, popovers, menus, and alerts.
- **Settings…** in the application menu, opened with **⌘,**.

The remote display should dominate the connection window. Avoid large control panels, decorative cards around the video, or permanently visible technical statistics.

Provide a compact toolbar containing:

| Control | Purpose |
|---|---|
| Connections | Open the connection manager or switch connections |
| Keyboard | Target keymap, native layout typing, paste, and shortcuts |
| Display | Video quality and display settings |
| Text Recognition | Select an area for local OCR |
| Actions | Reboot Comet and log out |

Place device configuration in **Settings → Devices**, not in another toolbar menu.

Show connection state clearly, with useful distinctions such as connecting, authentication required, reconnecting, and no HDMI signal.

## 3. Connection manager

Support multiple saved Comet connections and multiple simultaneous sessions.

Each saved connection should contain:

- A user-defined name.
- Hostname or IP address.
- Port and connection scheme.
- Authentication details.
- An optional **Remember password in Keychain** setting.
- Relevant preferences for that connection.

Users should be able to add, edit, remove, connect, and disconnect devices. Allow connections to open in separate windows.

Keep session state separate:

- Authentication and cookies.
- WebRTC connections.
- HID sockets and pressed-key state.
- Selected keymap.
- Audio state.
- Reconnection tasks.

Keyboard and mouse input must go only to the focused, captured session. Switching windows must release input held on the previous connection.

Support reconnecting after network interruptions and Mac sleep/wake. Do not replay old input after reconnecting.

Handle authentication expiry and firmware connection limits with clear messages.

## 4. Credentials and authentication

Use macOS **Keychain Services** for saved passwords. Users who do not enable password storage should be able to connect using credentials kept only for the session. [Apple Keychain documentation](https://developer.apple.com/documentation/security/keychain-services)

Do not store passwords in preferences, connection JSON files, logs, or crash diagnostics. Keep credentials scoped to the correct device and account.

Handle self-signed device certificates with a deliberate, device-specific trust flow. Do not disable certificate validation globally.

Logging out should end the selected session. Removing a saved password should be a separate, explicit action.

## 5. Comet API integration

Inspect the actual GLKVM source and any available reference client before implementing endpoints.

Relevant starting points include:

- [GLKVM repository](https://github.com/gl-inet/glkvm)
- [HID API implementation](https://github.com/gl-inet/glkvm/blob/main/kvmd/apps/kvmd/api/hid.py)
- The local `Overlook` project, if available.
- The companion Layout-Aware Typing daemon patch described below.

Firmware and hardware models differ. Discover capabilities and supported values rather than assuming every device exposes the same options.

Create a small API compatibility table covering authentication, state updates, HID, video controls, audio, reboot, and logout. Record which features are confirmed against real firmware.

Use persistent WebSockets for live HID input and state updates. Use the appropriate HTTP endpoints for settings and operations that already use HTTP.

Keep settings synchronized with the device. When updating a configuration object, preserve fields the app does not own.

## 6. Video rendering and performance

Implement the fastest practical native rendering path:

```text
WebRTC video
    → hardware decoding where supported
    → decoded CVPixelBuffer
    → Metal texture views
    → GPU color conversion and scaling
    → native display surface
```

Use decoded pixel buffers directly through **Core Video’s Metal texture cache** where the WebRTC decoder exposes compatible buffers. Core Video supports sharing image buffers with Metal through this mechanism. [Apple Core Video documentation](https://developer.apple.com/documentation/corevideo/cvmetaltexturecache-q3j)

The goal is to avoid unnecessary CPU copies between decoding and presentation. Compressed WebRTC packets still need decoding before they can be rendered.

Requirements:

- Prefer hardware decoding when the negotiated codec and device support it.
- Render through `MTKView`, `CAMetalLayer`, or an equivalent native Metal surface.
- Handle native pixel formats, including planar YUV, correctly.
- Perform color conversion and scaling on the GPU.
- Respect color space, video range, orientation, and pixel aspect ratio.
- Retain pixel buffers and texture resources until GPU work completes.
- Avoid converting every frame into `NSImage`, `CGImage`, JPEG, or PNG.
- Avoid sending every frame through SwiftUI state.
- Keep frame queues small and bounded.
- Present the newest usable frame rather than accumulating latency.
- Keep decoding, frame preparation, and networking off the main thread.
- Provide a clearly identified fallback when native texture sharing is unavailable.

Do not claim “zero-copy” without checking the actual decoder-to-renderer path.

Provide optional diagnostics for resolution, received FPS, presented FPS, bitrate, dropped frames, decoder type, and connection health. Distinguish network RTT and local rendering measurements from true end-to-end latency.

## 7. Fullscreen is a core feature

Treat fullscreen as a first-class mode throughout development.

Requirements:

- Use native macOS fullscreen and Spaces.
- Preserve the stream when entering or leaving fullscreen.
- Do not unnecessarily recreate the WebRTC connection or decoder.
- Support external monitors, Retina scaling, and displays with different scale factors.
- Preserve aspect ratio by default.
- Offer Fit, Fill, and Actual Size where practical.
- Clearly indicate cropping when Fill is selected.
- Keep overlays and controls within safe display areas.
- Remember window size and fullscreen preferences where appropriate.

In fullscreen:

- Hide toolbar chrome when it is not needed.
- Reveal controls predictably when the pointer approaches the top.
- Keep controls visible while a menu or popover is open.
- Avoid resizing the video whenever the toolbar appears.
- Make entering toolbar controls release or suspend remote input appropriately.
- Restore capture deliberately when returning to the video.
- Provide a clear local command to release input.
- Provide the standard fullscreen menu command and shortcut.

Define Escape behavior carefully:

- Escape cancels OCR selection first.
- Otherwise, it may need to reach the remote machine.
- Users must always have a reliable way to release capture and leave fullscreen.

Fullscreen transitions, focus changes, disconnects, and window closure must never leave remote keys or mouse buttons pressed.

## 8. Keyboard toolbar and input handling

The Keyboard toolbar button should show the active target keymap, for example **Keyboard · DE**.

Its popover should contain:

- Target keyboard layout.
- **Use Native Keyboard Layout** toggle.
- **Enable Paste with ⌘V** toggle.
- A clear Paste action.
- Common remote shortcuts.
- Optional custom shortcuts.

Render shortcuts with attractive native keycap-style symbols, such as **⌃**, **⌥**, **⇧**, and **⌘**, combined with readable labels.

Provide useful remote shortcuts such as Ctrl+Alt+Delete and Alt+Tab. Send balanced press/release sequences.

Clearly distinguish:

- The keyboard layout selected on the Mac.
- The target layout used by Comet to generate keystrokes.

The target layout must match the layout configured in the remote operating system.

Use AppKit’s keyboard events and modifier handling. Ordinary physical typing should preserve the existing Comet physical-key semantics.

Define which shortcuts stay local and which go to the remote machine. Local text fields, menus, and settings must retain normal macOS editing behavior.

## 9. Use Native Keyboard Layout

This is the app’s user-facing name for **Layout-Aware Typing**.

When disabled, send physical key events.

When enabled, use the text resolved by macOS and let the Comet daemon translate it through the selected target keymap.

For example:

```text
German Mac keyboard: Option+L
    → macOS resolves "@"
    → app sends "@" with target keymap "de"
    → Comet generates the target key sequence
    → German Windows receives "@"
```

**Do not implement a Mac-to-Windows character mapping table in the client.**

Use `NSEvent.characters` or the appropriate native text-input mechanism. Keep navigation keys, function keys, and shortcuts on the physical path.

The companion daemon patch provides this WebSocket event:

```json
{
  "event_type": "mapped_text",
  "event": {
    "text": "@",
    "keymap": "de"
  }
}
```

Its current contract accepts **one printable Unicode scalar per event**, not arbitrary strings or every Swift `Character`.

It advertises support as `mapped_text: true` in the keymap state returned through `/api/hid/keymaps`. A successful reply looks like:

```json
{
  "event_type": "mapped_text_result",
  "event": {
    "mapped": true,
    "text": "@"
  }
}
```

Failures return `mapped: false`; invalid requests may include `reason: "invalid"`.

Show this warning beside the setting:

> Requires the GLKVM Layout-Aware Typing daemon patch. Standard keyboard input and paste work without it.

Detect support from the capability flag. Do not assume support from a firmware name such as “Kratos.” Keep the option unavailable when the connected device does not advertise it.

Input handling must:

- Defer Shift and Option when they may produce text.
- Preserve Control and Command shortcuts.
- Consume releases for keys whose presses were translated.
- Support macOS repeat events for mapped characters.
- Preserve target-side repeat for held physical keys.
- Handle transitions between text and physical shortcuts.
- Release input and clear pending state on capture, focus, connection, keymap, or mode changes.
- Handle unmappable-character replies visibly.
- Avoid automatic retries that could duplicate text.
- Treat dead keys and composition explicitly; document any unsupported cases.

Use one ordered outbound HID queue for physical and mapped events. Avoid independent tasks whose scheduling could reorder modifier releases and characters.

## 10. Native paste with Command+V

When the remote video has focus and paste is enabled, **⌘V should type clipboard text into the remote machine**.

Use macOS pasteboard APIs and the existing Comet **`POST /api/hid/print`** endpoint, with the selected target keymap.

This is separate from the optional `mapped_text` extension. Paste must work on compatible stock firmware without that patch.

Requirements:

- Support Unicode text and multiline content.
- Consume the local paste shortcut so Command and V do not also reach the target.
- Give local text fields normal macOS paste behavior.
- Show a brief progress state for longer operations.
- Respect firmware text limits and avoid silent truncation.
- Do not automatically retry partially completed paste requests.
- Coordinate paste and live HID input so their keystrokes do not interleave.
- Avoid storing clipboard contents.

If cancellation cannot stop already queued device input, explain that limitation accurately.

## 11. Display toolbar and video controls

The Display button should expose the same video controls and presets as the original GLKVM application for the connected firmware.

Inspect the real options and their API mappings. Do not invent preset values.

Include supported controls such as:

- Quality presets.
- Resolution.
- Frame rate.
- Bitrate.
- Codec or video format.
- Quality versus latency preference.
- Encoder mode.
- Advanced GOP or keyframe settings.
- Relevant transport or recovery options exposed by that firmware.
- Local Fit, Fill, Actual Size, and rotation settings.

Distinguish device encoder settings from local presentation settings.

Respect capability flags and advertised limits. Reflect settings changed outside the app, debounce slider updates, and avoid unnecessary stream restarts.

## 12. Native settings and device controls

Provide a normal macOS Settings window.

Suggested sections:

- General
- Connections
- Devices
- Keyboard & Clipboard
- Appearance
- System
- Advanced

**Settings → Devices** must clearly identify which saved Comet is being configured.

Provide native controls matching the original GLKVM device options, including:

- Speaker/audio output.
- Microphone input and forwarding.
- Keyboard enablement and device options.
- Mouse enablement and device options.
- Absolute or relative mouse mode.
- Sensitivity, scrolling, and polling options where supported.
- Other exposed USB/device functions supported by the connected model.

Separate local audio choices from remote hardware changes. Muting playback on the Mac and disabling the Comet’s audio function are different operations.

Request microphone access when the user enables microphone forwarding. Keep its active state clear, and stop forwarding when disabled or disconnected.

Inventory the original device settings so the app does not quietly omit supported controls.

## 13. System: future hardware identity controls

Add a settings section named **System**.

This section is reserved for future configuration of the hardware identity presented by the KVM. More detailed requirements will follow.

Prepare an architecture that can support backend-exposed identity fields, such as USB descriptors and display/EDID identity.

For now:

- Establish the section and extension points.
- Keep proposed fields separate from confirmed API capabilities.
- Do not invent endpoints or build controls that pretend to apply changes.
- Do not promise arbitrary hardware spoofing beyond what the device supports.
- Allow future preview, validation, apply, and restore workflows.

Complete the rest of the app without waiting for these later requirements.

## 14. Actions menu

Include:

- **Reboot Comet…**
- **Log Out**

“Reboot Comet” must clearly mean the KVM appliance, not the attached computer. Show a concise confirmation, then handle the expected disconnect and reconnection.

Logout must release held input, stop the session’s media and network connections, and return to a clear disconnected state.

Both actions must target the selected connection only.

## 15. Native macOS OCR

Provide optional local OCR using **Apple Vision**, including `VNRecognizeTextRequest` or the appropriate current API. Text recognition should run on the Mac. [Apple Vision documentation](https://developer.apple.com/documentation/vision/recognizing-text-in-images)

The workflow should be:

1. Enter Text Recognition mode.
2. Capture a stable remote frame for selection.
3. Show a crosshair cursor and selection overlay.
4. Let the user drag a rectangle over the image.
5. Recognize text in that rectangle.
6. Present selectable text with a Copy action.

**During the selection drag, constrain the OCR cursor and rectangle to the actual displayed image bounds.** Letterboxing and toolbar areas are outside those bounds.

Requirements:

- Start selection only inside the image.
- Keep the selection cursor at the image edge when dragging beyond it.
- Release any temporary pointer confinement on mouse-up, Escape, focus loss, or cancellation.
- Never leave the system pointer trapped.
- Prevent OCR gestures and keys from reaching the remote machine.
- Correctly map selection coordinates to source pixels.
- Account for Retina scaling, rotation, zoom, Fill cropping, and letterboxing.
- Cancel cleanly if the underlying geometry becomes invalid.
- Run recognition away from the main thread.
- Support available recognition languages.
- Show useful empty-result and failure states.
- Avoid retaining images or recognized text unnecessarily.

Use the remote frame already available to the renderer. A one-time OCR conversion must not introduce CPU image conversion into the continuous video path.

## 16. Architecture and implementation

Keep responsibilities clear:

- Connection profiles and Keychain storage.
- Per-device API and authentication.
- Capability discovery and device state.
- WebRTC signaling and media.
- Metal rendering.
- Keyboard/mouse capture and ordered HID output.
- Paste coordination.
- OCR selection and recognition.
- Native views, menus, windows, and settings.

Use Swift concurrency with explicit ownership and cancellation. Keep UI state on the main actor, and keep high-frequency media work out of UI observation.

Choose a maintained WebRTC dependency that supports the intended macOS architectures. Document the minimum macOS version and codec limitations.

Handle the signaling protocol actually exposed by the device. Do not assume that the latest firmware uses the same signaling or supports every codec available in another model.

## 17. Acceptance checks and deliverables

Deliver a buildable Xcode project, setup instructions, API compatibility notes, and a short explanation of the rendering and input architecture.

Verify these scenarios:

- Two Comet sessions remain isolated.
- Input reaches only the focused session.
- Saved passwords use Keychain; unsaved passwords are not persisted.
- Fullscreen transitions preserve video and release input correctly.
- External-display and Retina changes preserve mouse accuracy.
- Ordinary physical input works on stock firmware.
- Unsupported firmware clearly disables native-layout typing.
- German letters and symbols—including `@`, `€`, brackets, braces, backslash, and pipe—work with the patched daemon and target layout `de`.
- Shortcuts, key repeat, Caps Lock, and modifier transitions behave correctly.
- ⌘V types text once, without leaking the shortcut or interleaving live input.
- Video controls match the connected firmware’s supported options.
- Device controls appear in Settings.
- OCR selection stays within image bounds and sends no remote input.
- Reboot, logout, network loss, and sleep/wake leave no stuck keys or mouse buttons.
- Video profiling identifies the actual decoder, texture path, frame queues, and any copies.

Measure performance and report the results. Clearly separate what was tested on hardware from what was tested with mocks or still needs manual verification.

Build the app in working stages, starting with **connection, video, fullscreen, and physical input**. Then add the native controls, layout-aware typing, paste, multiple sessions, and OCR. Keep the application usable at each stage.

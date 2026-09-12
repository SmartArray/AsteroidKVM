# Architecture

## Ownership

`CometCore` contains connection profiles, Keychain storage, lossless JSON values, the scoped API transport, capability/state models, display geometry, the input state machine, and the ordered HID queue. It does not depend on WebRTC or SwiftUI.

`CometMedia` owns Janus signaling, native WebRTC peer connections, decoded frame delivery, Metal rendering, and local Vision recognition. `MediaConnection` is the session-facing lifecycle contract. Its production implementation is `JanusClient`.

`CometSession` owns each session's authentication, state socket, ordered output, media connection, preferences, reconnection tasks, clipboard operation, and OCR task. `AppModel` coordinates profiles and focus across sessions. `RemoteSurface` is the AppKit adapter for precise key, modifier, mouse, window, and selection behavior.

`CometApp` contains the native SwiftUI scenes, toolbar popovers, profile editor, menus, and Settings. Fullscreen changes window presentation only; they do not recreate the peer or decoder. A forwarding window delegate preserves SwiftUI's original delegate and requests AppKit's fullscreen toolbar auto-hide behavior.

## Video path

```text
Janus / uStreamer WebSocket signaling
  → native WebRTC RTP / ICE / DTLS
  → default native decoder factory, with actual decoder reporting
  → RTCVideoRenderer callback on the WebRTC thread
  → latest-frame mailbox protected by a short lock
  → decoded CVPixelBuffer
  → CVMetalTextureCache plane texture views
  → GPU YUV conversion / rotation / scaling
  → MTKView
```

H.264 selected VideoToolbox in both local and hardware E2E tests. NV12 video/full range and BGRA buffers can share textures directly. Unsupported or cropped decoder buffers take an explicitly counted I420-to-NV12 CPU copy fallback. Texture-cache incompatibility switches subsequent frames to that fallback off the UI thread. This is not an unconditional zero-copy claim.

The mailbox has one replaceable newest-frame slot. The renderer retains its current frame and allows at most two outstanding GPU commands. Each command retains its pixel buffer and Core Video textures until completion. Frames do not enter SwiftUI observation. Low-frequency diagnostics do.

YUV conversion uses Rec.601/709/2020 matrix attachments and full/video range. ColorSync receives available color-space, primaries, and transfer-function metadata. One geometry model handles pixel aspect, rotation, backing scale, Fit/Fill/Actual Size, remote mouse coordinates, and OCR crops.

## Input path

AppKit physical key codes map to Comet's browser/USB key names. This is a physical-key table, not a character-layout table. Device modifier bits retain left/right Shift, Control, Command, and Option identity. Right Option therefore keeps physical AltGr semantics when native typing is disabled.

`InputEngine` defers modifier presses until the next event determines whether the action is a physical shortcut, mapped text, or local paste. Native typing uses `NSEvent.characters`, splits resolved strings into Unicode scalars, consumes corresponding key releases, and forwards repeat events. Physical repeat remains owned by the remote OS. Navigation and function keys stay physical. Control/Command shortcuts stay physical unless reserved locally.

`HIDOutput` has a single producer and a single draining task. Physical keys, mapped text, releases, and HTTP paste barriers share the FIFO. Absolute mouse events may coalesce; key transitions do not. Capture release discards stale queued input and releases every possibly held key/button. Paste locks live input synchronously and does not retry. Connection, focus, mode, keymap, sleep, and fullscreen changes release input.

Real Windows verification found modifier corruption when mapped events were sent in bursts and when HTTP paste used the firmware's fast rate. The production FIFO now waits 120 ms after each mapped event, and HTTP paste requests `slow=true`. Physical input retains its natural event timing. Mapped output is therefore capped near 8.3 scalars/second; use Paste for larger text. The test sends through this production pacing, verifies every mapped reply, and checks unique markers in the returned video with Vision.

Paste request deadlines scale with scalar count to accommodate the daemon's slow rate, while ordinary HTTP calls retain a 20-second deadline. Disconnect gives queued releases at most two seconds to drain, then cancels the transport; a stalled output cannot hold a window open indefinitely. Microphone permission work and device mutations are canceled with their session generation.

## Networking and secrets

Each API owns an ephemeral URLSession, private token, certificate policy, and sockets. Cookies, credentials, and caches are not shared across devices. Cross-origin and HTTPS-downgrade redirects are refused. Self-signed trust pins a leaf SHA-256 fingerprint to the profile's host and port. Two-step screen approval uses the documented completion flow, keeping its temporary token in memory.

The app declares an ATS exception because users provide arbitrary appliance hosts, may explicitly select HTTP, and can approve a self-signed device certificate. `DeviceTransport` still validates HTTPS certificates; no trust callback accepts every certificate. HTTPS remains the default and redirects cannot downgrade it. See [Apple's ATS configuration reference](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads).

Profiles cannot encode passwords or tokens. Keychain accounts include scheme, host, port, and username. Unremembered passwords stay inside their session. Removal of saved passwords is explicit and separate from logout.

Reconnection uses cancellable bounded backoff and a socket heartbeat watchdog. Old input is discarded and capture stays released after recovery. Optional settings are discovered before use; absent endpoints are distinguished from authentication/network errors. Whole configuration writes refresh and merge the current object to preserve unknown fields; the firmware offers no conditional-write/ETag mechanism, so cross-client writes still have an unavoidable read/write race.

## OCR

Selection holds a stable renderer frame. Mouse-down must be inside the actual visible image; the drag rectangle and cursor clamp to those bounds. Cursor confinement consists only of temporary drag-time warps, with no persistent pointer disassociation or event tap. Mouse-up, Escape, focus loss, geometry change, and teardown clear selection. Recognition converts only the selected snapshot and runs Vision away from the main actor. Results are discarded on dismissal.

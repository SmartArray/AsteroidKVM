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

`InputEngine` defers modifier presses until the next event determines whether the action is a physical shortcut, mapped text, or local paste. Native typing runs through the remote surface’s `NSTextInputClient` and AppKit input context. Marked text stays in a local preview; only `insertText` commits are normalized to NFC and split into Unicode scalars for `mapped_text`. Matching key releases are consumed, and repeat events remain supported. Escape during composition or capture loss discards pending text. Physical repeat remains owned by the remote OS. Navigation and function keys stay physical. Control/Command shortcuts stay physical unless reserved locally.

`HIDOutput` has a single producer and a single draining task. Physical keys, mapped text, releases, and HTTP paste barriers share the FIFO. Absolute mouse events may coalesce; key transitions do not. Capture release discards stale queued input and releases every possibly held key/button. Paste locks live input synchronously and does not retry. Connection, focus, mode, keymap, sleep, and fullscreen changes release input. A connected display acquires capture when its window or app becomes active, and on initial connection while focused. Sheets, toolbar popovers, OCR, paste, and local field editors block automatic capture. Ordinary state updates do not recapture after an explicit release. Pointer exit releases held HID state while preserving keyboard focus; switching windows releases capture through the session registry.

Real Windows verification found modifier corruption when mapped events were sent in bursts and when HTTP paste used the firmware's fast rate. The production FIFO now waits 120 ms after each mapped event, and HTTP paste requests `slow=true`. Physical input retains its natural event timing. Mapped output is therefore capped near 8.3 scalars/second; use Paste for larger text. The test sends through this production pacing, verifies every mapped reply, and checks unique markers in the returned video with Vision.

Paste request deadlines scale with scalar count to accommodate the daemon's slow rate, while ordinary HTTP calls retain a 20-second deadline. Disconnect gives queued releases at most two seconds to drain, then cancels the transport; a stalled output cannot hold a window open indefinitely. Microphone permission work and device mutations are canceled with their session generation.

## Networking and secrets

Each API owns an ephemeral URLSession, private token, certificate policy, and sockets. Cookies, credentials, and caches are not shared across devices. Cross-origin and HTTPS-downgrade redirects are refused. Self-signed trust pins a leaf SHA-256 fingerprint to the profile's host and port. Two-step screen approval uses the documented completion flow, keeping its temporary token in memory.

The app declares an ATS exception because users provide arbitrary appliance hosts, may explicitly select HTTP, and can approve a self-signed device certificate. `DeviceTransport` still validates HTTPS certificates; no trust callback accepts every certificate. HTTPS remains the default and redirects cannot downgrade it. See [Apple's ATS configuration reference](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads).

Profiles cannot encode passwords or tokens. Keychain accounts include scheme, host, port, and username. Unremembered passwords stay inside their session. Removal of saved passwords is explicit and separate from logout.

Reconnection uses cancellable bounded backoff and a socket heartbeat watchdog. Old input is discarded and capture stays released after recovery. Optional settings are discovered before use; absent endpoints are distinguished from authentication/network errors. Whole configuration writes refresh and merge the current object to preserve unknown fields; the firmware offers no conditional-write/ETag mechanism, so cross-client writes still have an unavoidable read/write race.

## OCR

Selection holds a stable renderer frame. Mouse-down must be inside the actual visible image; the drag rectangle and cursor clamp to those bounds. Cursor confinement consists only of temporary drag-time warps, with no persistent pointer disassociation or event tap. Mouse-up, Escape, focus loss, geometry change, and teardown clear selection. Recognition converts only the selected snapshot and runs Vision away from the main actor. Results are discarded on dismissal.

## Experimental agent ownership

`CometAgent` depends only on `CometCore`. `AgentComputer` is the pixel/input boundary; `AgentTransport` is the JSON-RPC boundary. `AgentController` coordinates conversation, lifecycle, bounded actions, and stale-screen rejection without knowing session credentials, WebRTC, AppKit, or SwiftUI. `SessionAgentComputer` in `CometSession` adapts one connection. `AppModel` owns one controller per session; `AgentChatView` renders it in a separate native window.

The Codex adapter launches the installed CLI directly through `Process` and stdio, with no shell interpolation. It initializes the experimental app-server API, reads account status, and starts an ephemeral thread with `comet_screen` and `comet_action` dynamic tools. The user's configured provider and model are retained; reasoning effort is medium. This process disables shell execution, local computer/browser tools, plugins, apps, hooks, memory, host skill discovery, and inherited MCP servers. Its working directory is an empty temporary agent directory; local sandbox policy is read-only. All unrelated approval or tool requests are rejected. Codex's tool host remains enabled because it dispatches the registered dynamic tools. None of these overrides rewrites the user's Codex configuration.

JSON-RPC output is framed on a dedicated reader queue. A serial writer sends screenshot responses off the main actor, keeping Pause responsive to pipe backpressure. Requests have 45-second deadlines. Process shutdown invalidates callbacks and resolves pending continuations. Only assistant prose, concise action records, and errors reach the UI; raw reasoning events and image payloads do not.

A screenshot is a one-time Core Image/JPEG conversion, capped at 1600 pixels on its longest side, outside the live Metal rendering path. Its coordinates refer to the full raw source frame, independently of local window scaling, cropping, or presentation rotation. The adapter maps those coordinates to signed absolute HID values. Arrival identity and wall-clock freshness are separate from decoder timestamps: real streams can deliver repeated timestamps while continuing to produce new frames.

The controller defaults to per-action approval, with explicit observation-only and full-control modes. Pending approvals bind one immutable action to a screen and endpoint/account/certificate identity. Pause, Stop, permission changes, target changes, and 60-second observation expiry invalidate approval. Session profile mutation is encapsulated; endpoint edits clear certificate exceptions before publishing or persisting the new value. Identity callbacks clear even idle agent threads, while the input adapter also checks identity at every lease boundary.

Every action consumes a unique screen ID and returns a new screenshot after input settles. Parallel tool requests, unknown keys, stale IDs, invalid coordinates, and oversized text are rejected. A single agent lease gates every input transition and every screenshot response. Pause invalidates that lease synchronously, cancels the current action, releases held input, and requests `turn/interrupt`; Resume waits for interruption and observes the current screen. An unsubmitted prompt survives startup pause. Stop terminates the process and drops thread context. Lifecycle generations prevent canceled tasks from affecting a newer run.

Agent typing uses the production FIFO one scalar at a time, with the existing mapped-text cadence; firmware without mapped-text support uses individual-character slow HTTP printing. It never sends a whole paragraph into the daemon's paste queue. Local focus changes release human input without discarding active agent input. Manual capture and configuration/lifecycle changes explicitly pause the agent first. Prompts instruct Codex to treat screen text as untrusted content and ask before destructive or external actions; semantic task correctness still depends on the model and should be reviewed on the remote display.


## Protocol and chat resource limits

`JSONValue.integer(in:)` checks exact representability and field bounds before converting protocol numbers to native integers. Numeric text formatting never traps on an out-of-range `Double`. ICE indices, video controls, and Codex response IDs use checked conversions.

`AgentTranscript` owns every timeline mutation, including deltas and completions. Count, per-message UTF-8 bytes, and total UTF-8 bytes are bounded; exhaustion stops control. The stdio reader admits one event to the main queue at a time, bounds its buffer to 1 MiB, and uses pipe backpressure. Screenshot writes have an independent 8 MiB queue budget. The stdin descriptor uses Darwin's `F_SETNOSIGPIPE`, and close runs on the serial writer queue, so subprocess exit cannot terminate the app or block Stop while output is pending.

`AgentLinkPolicy` permits only HTTP/HTTPS destinations without embedded credentials. The native chat intercepts URL opening and reveals the destination in a confirmation dialog; rendering never fetches previews or invokes local handlers.

# AsteroidKVM for iOS and iPadOS — implementation handoff

**Status:** implementation specification, with approved gesture artwork. The iOS app has not been implemented.

**Source baseline:** AsteroidKVM commit `8e56ac187cdd98bde902684fe55220c66b156e7f`, inspected 2026-09-29. The handoff requires the existing repository; it is not a standalone source distribution. Repository paths below refer to that checkout, while artwork links resolve inside this handoff.

## 1. Objective and fixed product decisions

Deliver a native iPhone and iPad KVM client from the existing Swift source, sharing connection, authentication, media, input, geometry, and OCR logic with macOS. Preserve the existing macOS product and release process.

The following decisions come from the product discussion and are requirements:

- Exclude MCP, the agent, OmniParser, and transcription from the iOS product, including their installers, processes, screens, and runtime dependencies.
- Support Absolute and Trackpad mouse modes. **Absolute is the default.**
- One finger controls the remote mouse; tapping clicks.
- Two fingers pan and zoom the local view.
- Three fingers scroll the remote machine. Do not replace this with two-finger scrolling or a required menu mode.
- A movable circular button opens a menu from the bottom. Users can drag it to another corner.
- Menu entries: **Close connection**, **Type**, **Special keys**, **Shortcuts**, **Settings**, **OCR**.
- Close connection requires a continuous two-second hold.
- Type presents a text area and confirmation button. Sending uses the existing typing API and immediately closes the editor and menu so the user sees the remote output.
- There is no remote typing-abort API. Do not add an abort button. There is no separate Paste button; the text editor supports normal system paste.
- Individual keys belong in Special keys; key combinations belong in Shortcuts.
- Settings use native iOS presentation and include screen-quality controls and all applicable existing settings.
- OCR uses a one-finger drag to select a rectangle.
- Include gesture onboarding, quick animations, and the supplied illustrations.
- **Images must contain no typography. All titles and explanations are separate code-rendered labels above the artwork.**

### Implementation defaults

These are engineering defaults, not additional user requirements. Adjust only when dependency checks or device testing justify a change and record the reason.

| Topic | Initial choice |
| --- | --- |
| Supported OS | iOS/iPadOS 17 or newer; verify dependency availability in milestone 1 |
| Devices | iPhone and iPad; portrait and landscape; resizable iPad layouts |
| Active sessions | One foreground remote session, multiple saved connection profiles |
| Navigation | Saved connections → remote view → floating menu → native sheets |
| Mouse mode | Absolute, persisted per connection; Trackpad selectable in Settings |
| Viewport | Fit initially; local zoom from 1× to 6× relative to fit; a Fit to Screen reset |
| Trackpad sensitivity | Reuse the existing preference and establish a sensible touch default through testing |
| Scrolling | Three-finger translation, natural content-following direction by default; configurable direction/sensitivity |
| Button placement | Bottom trailing safe-area corner initially; persist a corner rather than raw coordinates |
| Onboarding | Before first remote input; skippable, versioned completion flag, replayable in Settings |
| Animations | Short, interruptible transitions, approximately 180–250 ms; honor Reduce Motion |
| Appearance | Native system appearance and system fonts; supplied dark artwork can sit in a dark illustration card |
| Drafts | Memory-only per session; no text logging or persistent draft storage |

Full unattended/background operation, multi-window remote sessions, cloud sync, custom shortcut editors, and TestFlight publishing are not required for the first implementation. External keyboard/pointer input is included; platform-reserved combinations remain available through the explicit Shortcuts menu where needed.

## 2. Repository map and constraints

| Existing path | Role and implementation work |
| --- | --- |
| `Package.swift` | Currently macOS-only. Add the iOS platform and explicit shared/mobile products without making iOS compile desktop dependencies. |
| `scripts/generate-project.py` | Source of the checked-in Xcode project. Extend the generator for iOS targets, schemes, settings, assets, and tests; regenerate rather than hand-editing only the `.pbxproj`. |
| `AsteroidKVM.xcodeproj` | Keep existing macOS app/test targets; add `AsteroidKVMiOS` and mobile test schemes. |
| `Sources/CometCore/CometAPI.swift` | Authentication, networking, and `/api/hid/print` text submission. Preserve security and timeout behavior. |
| `Sources/CometCore/Models.swift`, `ProfileStore.swift` | Profiles, capabilities, preferences, and Keychain storage. Add backward-compatible mobile preferences. |
| `Sources/CometCore/InputEngine.swift` | `InputEngine`, `HIDEvent`, `HIDOutput`, ordered HID and paste barriers. Reuse these mechanisms. |
| `Sources/CometCore/DisplayGeometry.swift` | Coordinate conversion, rotation, pixel aspect, absolute HID range, and OCR crops. Extend or compose with a tested viewport transform. |
| `Sources/CometCore/VideoControls.swift`, `EDID.swift`, `EDIDService.swift` | Capability-aware stream presets and display configuration. |
| `Sources/CometMedia/JanusClient.swift`, `MediaConnection.swift`, `FrameMailbox.swift` | Shared streaming, decoder ownership, and latest-frame delivery. |
| `Sources/CometMedia/MetalVideoRenderer.swift` | Currently imports AppKit and reads `backingScaleFactor`; adapt screen scale, color-space configuration, and view integration for UIKit. |
| `Sources/CometMedia/TextRecognition.swift` | Reuse local Vision OCR. |
| `Sources/CometMedia/PlaybackAudioCapture.swift` | macOS ScreenCaptureKit transcription capture; keep outside the mobile build. |
| `Sources/CometSession/SessionController.swift` | Extract connection/media/HID/OCR lifecycle from desktop automation, transcription, and AppKit dependencies. |
| `Sources/CometSession/RemoteSurface.swift` | Desktop input adapter and useful event-shape reference; implement a UIKit counterpart. |
| `Sources/CometSession/DisplaySettingsController.swift` | Retain shared display-setting behavior and connection identity guards. |
| `Sources/CometSession/AppModel.swift` | Desktop app/window ownership; mobile needs its own navigation and lifecycle model. |
| `Sources/CometApp/SettingsView.swift`, `DisplaySettingsView.swift`, `SessionView.swift` | Inventory existing user-facing controls and capabilities; adapt presentation to mobile. |
| `Resources/AppIcon.png`, `Resources/ThirdPartyNotices.txt` | Existing branding master and notices, copied into this bundle under `branding/`. |
| `Tests/CometCoreTests/InputTests.swift`, `GeometryAndStorageTests.swift`, `SecurityTests.swift`, `TransportSecurityTests.swift`, `EDIDTests.swift` | Existing regression coverage; retain and extend meaningful shared tests. |
| `.github/workflows/macos.yml`, `.github/workflows/release.yml` | Preserve macOS validation and release behavior; add mobile build/test coverage separately. |

WebRTC is pinned to `153.0.0`. The locally installed XCFramework includes iOS arm64 and simulator slices. Confirm the pin and build compatibility in the implementor's checkout before changing dependencies.

Current text submission accepts at most **16,384 Unicode scalars**, uses `slow=true`, and has a size-dependent request timeout. The default **50 ms mapped-key interval** is a separate setting and does not control the firmware HTTP print rate. Preserve this distinction in UI copy and tests.

## 3. Target architecture

```text
AsteroidKVMiOS — SwiftUI navigation, forms, onboarding, sheets
    |
    +-- UIKit remote surface — touch recognizers, keyboard/pointer events
    |       +-- viewport transform shared with rendering and OCR
    |
    +-- shared session core — connection, state, media, ordered input, OCR
            +-- CometCore — API, models, profiles, geometry, HID
            +-- CometMedia — WebRTC, mailbox, Metal, Vision

Existing macOS app/session adapters
    +-- shared session core
    +-- AppKit, MCP, agent, OmniParser, transcription
```

Introduce a shared session module, provisionally `CometSessionCore`, as the extraction boundary. Existing `CometSession` becomes the desktop adapter/composition layer. If an equivalent smaller separation works better, preserve the same dependency direction and document it. Do not duplicate the session state machine for iOS.

The mobile dependency graph must not compile `CometAgent`, Python process management, MCP listeners, or ScreenCaptureKit transcription. Pure shared data definitions may remain if harmless; excluded features must not initialize at runtime. Place platform checks at file/module or adapter boundaries, not throughout UI code.

Suggested mobile components (names are proposals):

- `MobileAppModel`: saved connections, active session, scene lifecycle, onboarding state.
- `MobileSessionView`: stable video surface and UI overlays; never recreate the decoder when presenting a sheet.
- `MobileRemoteSurface`: UIKit host for the Metal view, gestures, and external input.
- `GestureCoordinator`: recognition state and exclusive ownership of each interaction.
- `ViewportTransform`: local fit/zoom/pan composition and inverse coordinate mapping.
- `FloatingMenuButton` and `ConnectionMenuSheet`.
- `TypeSheet` with a session-owned submission operation.
- `SpecialKeysSheet`, `ShortcutsSheet`, `MobileSettingsView`, and `OCRResultSheet`.
- `GestureOnboardingView`: local, non-forwarding tutorial pages.

Use async/await and dependency-injected API/media/input interfaces. Keep UI state on the main actor, recognition/image conversion off it, and high-frequency frames outside SwiftUI observation. Keep session identity/generation checks so callbacks from an old connection cannot update or control a new one.

## 4. Connections, media, and lifecycle

Provide saved-connection list, add/edit forms, connect, credential storage choice, explicit certificate approval, and readable connecting/connected/no-signal/reconnecting/failed states. Reuse existing account and capability flows rather than inventing a second protocol.

- Retain isolated credentials, certificate pinning, origin checks, bounded reconnect backoff, and no replay of old input.
- Use Keychain for remembered secrets. Do not log credentials, typed text, OCR content, or frames.
- Include the local-network permission explanation. Add discovery declarations only for discovery actually implemented; manual hostname/IP connection must work.
- Preserve the bounded latest-frame mailbox and GPU rendering path. Pan/zoom must not trigger stream renegotiation or CPU image conversion on each frame.
- Adapt the existing renderer to an iOS `MTKView`, including display scale and color-space handling. Keep rendering, hit testing, and OCR on one consistent transform.
- Configure iOS audio playback and interruption/route handling. If existing microphone forwarding is supported in mobile settings, request permission only when enabled; transcription remains excluded.
- On inactive/background transitions, release held input while execution is available, suspend remote interaction, and stop or suspend media/network activity appropriately. Do not claim indefinite background streaming.
- On return, reconnect if necessary and require fresh active state before forwarding input. Closing the connection cancels local work and disables reconnect; it cannot retract text already accepted by firmware.
- Prevent auto-lock only while the remote session is actively being viewed, then restore normal behavior.

## 5. Gesture contract and coordinate safety

| Gesture | Absolute mode | Trackpad mode |
| --- | --- | --- |
| One-finger movement | Move pointer to the touched image location | Send relative movement without jumping to touch-down location |
| Tap | Position pointer at touched location, then left-click | Left-click at current remote pointer position |
| Double-tap | Remote double-click at touched location | Remote double-click at current pointer |
| Long-press | Position and right-click once | Right-click once at current pointer |
| Double-tap, hold, then move | Left-button drag following touched position | Left-button drag following relative movement |
| Two-finger pan | Move local viewport | Same |
| Two-finger pinch | Zoom around pinch anchor | Same |
| Three-finger swipe | Remote wheel scrolling | Same |

Use explicit one-/two-/three-touch recognizer ownership. Two-finger pan and pinch may recognize together; remote mouse/scroll/OCR/menu interactions must not. Do not fire remote clicks on initial touch-down. Suppress pending taps when another gesture takes ownership. Once dragging, always emit button-up on completion, cancellation, extra fingers, connection loss, sheet presentation, or lifecycle interruption. A double-tap-hold may include its intentional first tap, but must not add a trailing click after the drag.

Recognize taps promptly while distinguishing double-click and drag without duplicating HID button transitions. Tune timings on physical devices; avoid a long recognition delay on every click. Adding fingers must never leave a button held or replay the earlier movement later.

### Coordinate mapping

Compose local pan/zoom with the existing fit, source rotation, pixel aspect, and screen-point/pixel geometry. Apply the inverse transform to touches before using existing source-coordinate/HID conversion. Ignore touches that start in letterboxing or local chrome; clamp valid active drags at source edges. Pinch zoom retains the source point under its anchor. When content is smaller than the viewport, keep it centered; otherwise bound panning so the image remains reachable.

Do not scale raw touch coordinates directly to HID values without undoing local zoom/pan. Rotation and iPad resizing cancel active gestures and recompute geometry. Save mouse mode/preferences, but reset viewport to fit when connecting to a different source.

For Trackpad mode, reuse the firmware `mouse_relative` event shape and signed-byte limits used in `RemoteSurface`. Accumulate fractional deltas and split large deltas into bounded packets without losing total movement. Coalescing absolute motion is already supported; do not apply replacement coalescing to relative deltas because that loses distance.

For scrolling, use three-finger centroid translation, accumulate fractional wheel increments, and emit bounded `mouse_wheel` values through the ordered output. Do not synthesize momentum initially. Scrolling targets the current remote pointer location without clicking; explain that users can position the cursor over the desired panel first. Restrict horizontal output to supported firmware behavior.

System accessibility and editing gestures may intercept three-finger input. Handle cancellation cleanly, explain the limitation, and provide accessibility scroll actions on the remote view. This is not a promise to override system gestures or a reason to disable system accessibility globally. Validate what can be configured on the remote surface without breaking the Type editor's native editing gestures.

## 6. Floating menu and action sheets

Use a circular control with a minimum 44-point hit area, clear contrast over video, and a descriptive accessibility label. A tap presents the bottom sheet; a drag moves only the control, snapping to the nearest safe-area corner. Save the logical corner, adapting it to orientation, iPad size, and keyboard position. Dragging the button must not touch the remote input path.

The bottom menu contains these entries in this order:

| Entry | Specification |
| --- | --- |
| Close connection | Two-second continuous hold, visible progress ring, cancellation on early release/drag-away/dismissal, haptic confirmation on completion. Then disconnect and return to saved connections. |
| Type | Open native text editor with Cancel and Send. See submission contract below. |
| Special keys | Grid/list of individual keys: Esc, Tab, Enter, Backspace, Delete, arrows, Home, End, Page Up, Page Down, F1–F12; use established firmware key codes. |
| Shortcuts | Predefined combinations: Ctrl+Alt+Del, Ctrl+C/X/V/A/Z, Alt+Tab, and useful target-specific Command combinations. Display actual modifiers explicitly. |
| Settings | Native grouped settings for app, current connection, and supported remote controls. |
| OCR | Dismiss menu and enter one-frame rectangular selection mode. |

Special keys and shortcuts use balanced down/up events through the shared HID queue; release combinations in reverse order. Remote Ctrl+V is a remote shortcut, not access to the phone's clipboard. Close the key/shortcut sheet after sending so results are visible. Disable HID actions when disconnected, unavailable, or blocked by an in-flight text operation.

The long-hold disconnect control needs accessible progress feedback. Under accessibility input that cannot perform the physical hold reliably, provide an explicit confirmation path with equivalent deliberate intent; no accidental single-activation disconnect.

### Text submission contract

1. Open a native multiline editor and focus it; retain system selection, paste, and IME behavior. Use code-friendly defaults for autocorrection, capitalization, and smart punctuation so commands are not silently changed.
2. Disable Send for empty input or an in-flight operation. Validate the existing Unicode-scalar limit before dismissal and show an inline error for oversized input.
3. On Send, atomically transfer the exact text and current keymap to a session-owned operation, lock duplicate submissions, and dismiss both the editor and menu immediately.
4. Add a text-argument session entry point rather than calling the current `SessionController.paste()` that reads `NSPasteboard`. Submit through `HIDOutput.paste(text,keymap:)` and the existing `CometAPI.paste` path; preserve its release/barrier, `slow=true`, limit, and timeout behavior.
5. The operation must outlive the sheet. Avoid attaching it to a sheet `.task` that is cancelled on dismissal. Keep live video visible and optionally show a small nonblocking sending indicator.
6. Preserve the existing HID lock while the request is in flight. Do not let sheet dismissal or an unrelated local capture release discard a queued text operation. Review the current `HIDOutput.releaseAll()`/paste lifecycle during extraction and cover it with tests.
7. Never automatically retry. If an outcome is uncertain, report that text may already have been sent and keep the draft available for deliberate editing/resubmission. Do not imply an HTTP response proves visible typing is complete.
8. There is no Abort button. A disconnect/background transition cannot undo text accepted by firmware. Do not label a local request cancellation as remote cancellation.
9. Retain failed/unsent drafts only in memory; clear successful submissions and dispose drafts when their session is removed. Do not put text in logs, analytics, or restored app state.

The native typing interval remains 50 ms by default where mapped-key input uses it. Label it precisely; the multiline Type API has its own firmware-controlled pacing.

## 7. Settings and OCR

Use SwiftUI native forms, pickers, toggles, navigation titles, and system fonts. Adapt compact and regular widths without copying the desktop sidebar. Audit every existing settings group; map each to mobile, a capability-gated control, or an explicitly excluded desktop feature. Do not silently omit relevant device controls.

| Group | Contents |
| --- | --- |
| Connection | Saved profile, endpoint, credentials policy, connection status, certificate details/approval flow |
| Mouse and gestures | Absolute/Trackpad, sensitivity, scroll direction/sensitivity, Gesture Guide |
| Keyboard | Target layout, supported native keyboard behavior, mapped-key interval (50 ms default), applicable physical-key options |
| Screen and stream | Existing quality presets, supported resolution/FPS/bitrate/GOP/codec options, local scaling/rotation, Fit to Screen |
| Display/device | Existing supported display identity/EDID and hardware controls, with their current validation and apply/restore behavior |
| Audio | Remote playback mute/volume as available; microphone forwarding only if supported and permissioned |
| Appearance and help | System/light/dark appearance, Gesture Guide, version and notices |

Use discovered parameters and limits; do not fabricate quality settings that the device does not advertise. Keep local viewport changes separate from encoder mutations. Debounce slider changes, preserve unknown firmware configuration keys, surface errors, and retain existing safeguards for disruptive device/display changes. Do not add speculative USB identity controls that are placeholders in the desktop app.

### OCR flow

Capture one stable decoded frame and freeze it for selection. One-finger dragging draws a visible rectangle instead of sending mouse input. Show Cancel immediately. On release of a nontrivial rectangle, convert through the same inverse viewport transform, crop in exact source pixels, and run Vision away from the main actor. Clamp bounds and ignore empty selections. Freeze geometry during selection or cancel it on resizing/rotation.

Present recognized text in a selectable native sheet with Copy, Retry, and Cancel/Done. Retry returns to selection on the same snapshot; leaving and re-entering OCR captures a new frame. Clearly show no-text and recognition-error states. Restore live video and normal gestures on exit; drop late results after dismissal or connection changes. No cloud service is involved.

## 8. Onboarding content, accessibility, and assets

Present a short walkthrough before first remote interaction. Include Skip, Next, Back, and Get Started, page indicators, a persisted onboarding-version flag, and Settings → Gesture Guide. Explicit skip marks that version as seen; termination midway does not. Do not forward any tutorial input to the KVM.

| Page | Code-rendered title | Code-rendered explanation | Visual |
| --- | --- | --- | --- |
| 1 | Point and click | Move one finger to position the pointer. Tap to click. Absolute mode is on by default; choose Trackpad in Settings. | `one-finger-pointer.png` |
| 2 | Pan and zoom | Drag with two fingers to move the view. Pinch to zoom. These gestures change your view, not the remote computer. | `two-finger-pan-zoom.png` |
| 3 | Scroll remotely | Position the pointer over the area you want to scroll, then swipe with three fingers. | `three-finger-scroll.png` |
| 4 | Your controls, within reach | Tap the round button to open controls. Drag it to move it to another corner. | Code-rendered, locally interactive floating-button preview |

Page 1 includes secondary guidance for long-press right-click and double-tap-hold dragging. Page 3 includes: “Some iOS accessibility and editing gestures may take priority over three-finger scrolling.” The replayable guide includes all gestures and accessibility alternatives so first-run pages stay readable.

Labels must be localized `Text` views placed above the image, not text baked into a bitmap. Use a scrollable layout when Dynamic Type would otherwise clip content. Mark decorative images as accessibility-hidden when nearby text already explains them. Keep accessible focus order coherent and support accessible controls/scroll actions. Use native text contrast even when artwork uses vivid accents.

### Supplied asset inventory

| File | Dimensions | Use |
| --- | --- | --- |
| [onboarding/one-finger-pointer.png](onboarding/one-finger-pointer.png) | 1254 × 1254 PNG | Pointing/tapping page |
| [onboarding/two-finger-pan-zoom.png](onboarding/two-finger-pan-zoom.png) | 1254 × 1254 PNG | Viewport navigation page |
| [onboarding/three-finger-scroll.png](onboarding/three-finger-scroll.png) | 1254 × 1254 PNG | Remote scrolling page |
| [branding/AppIcon.png](branding/AppIcon.png) | 1254 × 1254 PNG | Existing brand master; prepare a valid mobile app-icon asset set during implementation |
| [branding/ThirdPartyNotices.txt](branding/ThirdPartyNotices.txt) | Text | Existing dependency notices; audit applicability for the mobile product |
| [onboarding/README.md](onboarding/README.md) | Markdown | Generation provenance and exact prompts |

The three gesture images were generated with the built-in image generation tool and approved by the user. Retain originals. Do not regenerate or add fonts unless asked. Use aspect-fit, preserve full fingers/arrows, and keep the navy background; these are opaque images, not transparent cutouts. No separate font files are needed.

Palette guidance: navy `#090919`, indigo `#24234A`, electric blue `#4967FF`, magenta `#FA087E`, teal `#19CEC0`, with pale lavender hands. These are design intent values; generated pixels can vary. The original dashboard reference is inspiration only and is not an app screen or asset to ship.

Import artwork into the new app asset catalog as named image sets (for example `GesturePointer`, `GesturePanZoom`, `GestureScroll`), generating optimized derivatives only if needed. Do not stretch 1254-pixel sources into invented higher-resolution detail. Follow Xcode's supported app-icon asset format for the brand master; do not ship the macOS `.icns` as the iOS icon. Put licenses/notices in an accessible About screen and the bundle.

Use approximately 180–250 ms interruptible animations for page changes, corner snaps, and custom transitions; retain native sheet behavior where appropriate. Under Reduce Motion, use simple fades or immediate transitions. Light haptics accompany meaningful confirmation/snap events, not every pointer move. The disconnect hold is always two seconds apart from its explicit accessibility alternative.

## 9. Persistence and state boundaries

- Store global appearance, floating-button corner, and onboarding version as local app preferences.
- Store mouse mode, input sensitivities, target keyboard options, and applicable connection preferences per profile with backward-compatible decode defaults.
- Keep viewport transform, touch ownership, pressed keys/buttons, pending Type content, OCR snapshot/results, and request IDs transient.
- Never persist held input or replay it after restoration. No transcript/history is added.
- Present one local sheet/action at a time. Menu/editor/OCR transitions release physical held input without inadvertently cancelling an accepted session-owned text operation.
- Model connection availability separately from local input mode and text-request activity so state changes do not silently re-enable remote input.

## 10. Implementation milestones

Each milestone should leave the desktop build usable. Keep commits focused on the shared extraction, mobile functionality, tests, or docs they introduce.

| Milestone | Work | Exit criteria |
| --- | --- | --- |
| 1. Build boundaries | iOS platform/products, shared session extraction, media portability, project generator, mobile target/scheme, basic icon/notices | Shared modules and empty mobile shell compile for device and simulator; excluded services absent; macOS tests/build pass |
| 2. Connect and view | Saved profiles, auth/trust, state, WebRTC video/audio, lifecycle and reconnect | Physical device connects to a KVM and displays stable video; disconnect/background/return do not replay input |
| 3. Input and viewport | Absolute/Trackpad, taps/right-click/drag, two-finger pan/zoom, three-finger scroll, external input | Correct pixel targeting at all transforms; no unintended clicks/stuck buttons during gesture transitions |
| 4. Menu and typing | Movable button, native sheet, disconnect hold, session-owned API typing | Menu never controls remote by accident; Type disappears immediately and request continues without duplication |
| 5. Keys/settings/OCR | Special keys, shortcuts, full applicable settings inventory, quality controls, snapshot OCR | Real device responds correctly; settings respect capabilities; OCR crop/result is correct and local |
| 6. Onboarding/polish | Asset catalog, localized labels, replayable tutorial, animations/haptics, accessibility | First-use/replay/skip behave correctly; artwork has no labels; layouts work with large text and Reduce Motion |
| 7. Verification/delivery | Automated regression tests, device matrix, iOS CI, setup and usage docs | Acceptance matrix recorded, mobile build artifact available, macOS unchanged in behavior |

Do not bypass milestones 1–3 with a standalone demo that cannot integrate into existing sessions. Prioritize working input and lifecycle over ornamental effects.

## 11. Tests and acceptance criteria

Automated tests should target contracts and failure modes rather than mirror view implementation.

| Area | Required checks |
| --- | --- |
| Geometry | Fit/zoom/pan inverse mapping; all supported rotations; pixel aspect; letterboxing; clamp; pinch anchor; OCR crop bounds; device rotation/resizing |
| Gestures | Single vs double tap; long-press; drag lifecycle; 1→2→3 finger transitions; recognizer cancellation; simultaneous pan/pinch; menu and OCR suppression |
| HID | Balanced button/key pairs; relative delta accumulation/splitting; wheel conversion/sign; no input when disconnected; no replay after reconnect |
| Typing | Exact multiline text/keymap; Unicode-scalar limit; empty/oversized text; immediate dismissal without cancellation; duplicate Send protection; ordered barrier; failure/timeout without retry; retained memory-only draft |
| Local actions | Button snapping/persistence/safe areas; two-second disconnect and early cancellation; shortcuts release order; local editor keyboard never reaches remote |
| Settings | Capability-gated controls, limits, debouncing, stale connection callbacks, old profile decode, 50 ms mapped-key default preserved |
| OCR | Stable snapshot, correct crop after zoom/rotation, no remote gestures during selection, no text/error states, cancellation and late-result rejection |
| Onboarding | First presentation, Skip/Get Started persistence, interrupted walkthrough, replay, native labels and accessible reading order |
| Lifecycle/security | Background input releases, reconnect, auth failure, trust approval, network denial, microphone permission if used, no sensitive logging |
| Regression | Existing macOS core/unit/build checks and relevant shared media tests |

Use injected transports and existing local fixtures for deterministic tests. Put mobile UI tests in a mobile target; the current aggregate desktop test target includes AppKit and excluded feature suites and must not simply be enabled wholesale on iOS.

Physical acceptance testing must include an iPhone and iPad, portrait/landscape, small and large text, mouse/keyboard where available, and a real KVM. Record tested device/OS/firmware versions. Exercise VoiceOver, system Zoom/editing gesture conflicts, and Reduce Motion. Verify both pointer modes, all multi-touch transitions, text visibility after sending, long text/error behavior, audio interruption, local-network permissions, and network loss/recovery. Simulator success is not proof of multi-touch or hardware media performance.

Use synthetic/local images for repeatable OCR checks. No cloud perception or model download is needed. Do not send arbitrary text or configuration changes to a real KVM as part of unattended CI; physical acceptance uses an explicitly selected test target.

### Suggested build workflow

Existing regression commands remain:

```sh
./scripts/test.sh --unit
./scripts/build.sh
```

After implementing the new project generator and schemes, add equivalents of:

```sh
python3 scripts/generate-project.py
xcodebuild -project AsteroidKVM.xcodeproj -scheme AsteroidKVMiOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/iOSDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project AsteroidKVM.xcodeproj -scheme AsteroidKVMiOS \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/iOSDeviceDerivedData CODE_SIGNING_ALLOWED=NO build
```

These mobile commands describe future schemes and are not runnable against the baseline. For tests, select an installed simulator from `xcodebuild -showdestinations`/`xcrun simctl list devices available`; do not hard-code an unverified runner device name. Real-device installation requires the implementor's signing team/provisioning. Do not commit signing secrets.

Add a mobile CI job with read-only repository permissions for simulator build/tests and unsigned device compilation as appropriate. Keep the current macOS release workflow intact. A signed/TestFlight release is a later distribution step, not part of this handoff or an automatic publication request.

## 12. Definition of done and deliverables

- [ ] Shared-source iPhone/iPad app target and reproducible project generation.
- [ ] Saved connections, auth/trust, video/audio, lifecycle, and reconnect work.
- [ ] Absolute default, Trackpad option, all agreed gestures and safe cancellation work.
- [ ] Movable corner-snapping button and complete native menu work.
- [ ] Type closes immediately, sends through the existing API, and has no abort/paste button or automatic retries.
- [ ] Special keys and shortcuts are separate and use balanced HID events.
- [ ] Applicable settings including stream quality are mapped and capability-aware.
- [ ] Local OCR rectangle selection and copyable results work.
- [ ] Supplied images are integrated without embedded typography; labels are localized code.
- [ ] First-use onboarding, replay, accessibility, and Reduce Motion work.
- [ ] MCP, agent, OmniParser, and transcription do not ship or initialize in iOS.
- [ ] Focused tests, iOS CI, and physical acceptance results are documented.
- [ ] macOS regression validation passes.
- [ ] README/setup instructions explain building, signing, connecting, gestures, and known platform limitations.

The final implementation report should list source changes, build/test commands and results, tested devices, unresolved limitations, and any justified deviations from this specification. This handoff itself contains documentation and assets only; it does not claim those implementation acceptance criteria have passed.

## 13. State-transition reference for the implementor

Use separate connection state, local interaction state, and text-submission state. This avoids treating a dismissed sheet as a disconnected session or treating a displayed video frame as proof that remote input is ready.

### Local interaction ownership

| Current state / trigger | Result | Input invariant |
| --- | --- | --- |
| Remote idle → one-finger motion | Absolute move or relative move | No mouse button is held merely because a finger is down |
| Remote idle → recognized tap | One balanced click | Absolute positioning precedes button-down in the same ordered queue |
| Pending tap → second/third finger | Cancel pending tap; hand off to viewport/scroll recognition | No delayed click after the multi-finger gesture finishes |
| Remote drag → extra finger or system cancellation | Balance button-up and end drag before another recognizer owns input | Never carry a held button into panning or scrolling |
| Any remote interaction → menu/settings/editor | Release physically held input; local UI owns events | Local button taps and text edits are never forwarded |
| Local editor → accepted Send | End local editing, enqueue owned text operation, return to video | Dismissing local UI does not cancel the text request or enqueue it twice |
| Text request in flight → remote gesture | Ignore/disable conflicting HID until the existing barrier opens | Never interleave keys/shortcuts with pending text printing |
| Remote idle → OCR | Snapshot frame and geometry; selection owns input | Drawing the rectangle emits no HID |
| OCR → exit/resize/disconnect | Cancel selection/results; resume live display when connected | Late OCR callbacks cannot resurrect a sheet or act on a new connection |
| Any interaction → inactive/disconnected | Release held input where possible; invalidate pending gestures | Do not defer old physical input until reconnection |

Touch recognizers should consume normalized interaction intents; the session boundary decides whether input is currently permitted. Do not depend solely on disabled SwiftUI buttons, because external keyboard events and already-queued callbacks can arrive independently.

### Text operation states

Suggested states: `draft`, `queued`, `requestInFlight`, `requestSucceeded`, `failed`, and `outcomeUnknown`. Only `queued` and `requestInFlight` block a second submission. Give each operation an ID plus session generation so an old failure cannot overwrite a later draft or another connection's status. These are internal state names, not technical labels to expose in product UI.

The existing output layer has queue-wide paste/error callbacks. Add the smallest operation-specific completion/result reporting needed for the mobile editor rather than polling a sheet's lifecycle or assuming any global error belongs to the latest submission. Preserve existing desktop callers through a compatible adapter.

Examples of user-facing failures:

- Validation failure before enqueue: keep the editor open and explain the supported text limit.
- Connection unavailable before enqueue: keep the draft and let the user reconnect.
- Request fails after it may have reached firmware: return to the stream and show “Typing may have started. Check the remote screen before sending again.” Keep the draft in memory for manual recovery.
- Session closed or app suspended during an uncertain request: do not retry after reconnect and do not claim the remote operation was stopped.

For a successful HTTP request, “Text sent” is an acknowledgment of the request, not a promise that every remote application has processed every character. Do not invent a percent-complete indicator without firmware support.

## 14. Review checklist and known implementation risks

| Risk | Required mitigation / evidence |
| --- | --- |
| Shared extraction accidentally pulls desktop services into iOS | Inspect target dependencies and resource build phases; device and simulator compile checks; verify no parser scripts/models or desktop process startup |
| Project regeneration drops the mobile target or assets | Add target/resource/scheme generation to `scripts/generate-project.py`; regenerate twice and require a stable second result |
| Extra fingers cause unintended remote clicks | Recognizer-transition tests and slow/fast physical multi-touch tests on both phone and tablet |
| Trackpad delta coalescing loses movement | Sum/split relative deltas instead of replacing them; verify aggregate output against input under queue pressure |
| Finger position disagrees with video after zoom | One transform shared by rendering, touch mapping, pointer overlays, and OCR; corner/center checks after rotation and panning |
| Closing the Type sheet cancels or duplicates typing | Session ownership, atomic Send state, operation IDs, and dismissal/failure tests |
| OS intercepts three-finger gestures | Device testing, clear onboarding copy, cancellation handling, and accessible scroll actions; document limitations honestly |
| Default system text transformations corrupt commands | Disable automatic substitutions where possible in the editor; verify multiline, quotes, whitespace, accents, and local paste |
| An unknown KVM capability is represented as a working setting | Explicit loading/unavailable states and capability-based controls; use existing validation and error paths |
| Unintended product scope expansion | Keep the four excluded feature groups out; do not add custom shortcut editing, account systems, cloud services, or discovery infrastructure solely for this port |
| Assets look blurry or are clipped at large sizes | Aspect-fit and bounded layout; inspect full fingers/arrows and text placement in compact/regular widths; keep originals untouched |
| Test suite reports success without exercising mobile behavior | Separate shared unit, mobile UI, media integration, and physical-device results in the final report |

Reviewable implementation commits should follow milestone boundaries where practical. The implementor should update this plan only for actual deviations, leaving a concise record of why they were necessary. User-mandated interaction choices take precedence over the engineering defaults in section 1.

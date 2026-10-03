# AsteroidKVM for iPhone and iPad

Native iOS/iPadOS 17+ client. Open `../AsteroidKVM.xcodeproj` and select **AsteroidKVMiOS**. The app uses the repository’s existing Comet protocol, authenticated transport, WebRTC 153.0.0, Metal renderer, input queue, Vision OCR, Keychain, and EDID controller.

## Build and install

From the repository root:

```sh
python3 scripts/generate-project.py
./scripts/ios.sh build
./scripts/ios.sh device
./scripts/ios.sh test                     # chooses an installed iPhone simulator
./scripts/ios.sh test <simulator-UUID>    # choose an iPad or another device
```

The simulator app is `build/iOSDerivedData/Build/Products/Debug-iphonesimulator/AsteroidKVMiOS.app`. The unsigned device app is `build/iOSDeviceDerivedData/Build/Products/Debug-iphoneos/AsteroidKVMiOS.app`. An unsigned device build validates compilation; it cannot be installed on a phone as-is. In Xcode, choose your signing team for the mobile target, select the attached device, and Run. Keep signing credentials out of Git. No TestFlight publication is configured.

Project generation includes dedicated mobile unit/UI test targets. The existing macOS scheme and release workflows remain intact. iOS dependencies are `CometCore → CometMedia → CometSessionCore`; desktop automation, agent, MCP, parser processes/resources, and ScreenCaptureKit capture are outside this graph. The mobile shell and resources live here; shared code stays under `Sources`.

## First launch

A four-page welcome tour appears before the connection list the first time the app opens. It introduces AsteroidKVM as a client made for **Comet KVM**, explains live video/audio and touch control, highlights the keyboard, special keys, shortcuts and on-device text recognition, and explains saved connections and optional Keychain storage. Completing or skipping the tour persists across launches. Replay it with **Connections → More → Welcome tour**.

Swipe left or right in both the welcome tour and gesture guide. Back/Next, Skip and Get Started remain available, and VoiceOver can adjust the page indicator. Vertical scrolling accommodates large text and short screens. The welcome tour and first-connection gesture guide have separate completion states, so finishing the welcome tour does not hide gesture instructions.

## Connect

Add a name, hostname/IP, port, scheme, and username. Enable **Remember password in Keychain** to retain credentials; otherwise enter the password on each connection. Editing the endpoint clears its old certificate exception. A self-signed certificate requires fingerprint approval. Allow the local-network prompt when connecting to your appliance. HTTP is supported for appliances configured for it; HTTPS is the default. Transport origin restrictions and certificate pinning remain enforced by the shared transport.

Swipe a connection to edit or delete it. Disable remembered credentials in its editor to remove them; use **Reset certificate trust** there to require fresh approval. Only one foreground session runs. Backgrounding releases physical input and closes media/transport; returning reconnects eligible sessions without replaying old input. Remote audio is muted when an audio output device is disconnected. Microphone permission is requested only when forwarding is enabled.

Use **Test connection** below the editor fields to check the entered credentials and KVM APIs before saving. A successful test shows a green checkmark and success haptic; failures show red feedback and the reason. Self-signed certificates require explicit approval. Editing the address or credentials clears the result, and Cancel test stops an in-flight check. The test signs out afterward and never starts video or sends input.

## Controls

- **One finger:** absolute pointer movement; tap to click, double-tap to double-click, long-press to right-click, double-tap then hold/move to drag. Trackpad mode sends relative motion without jumping to touch-down. Selecting a mouse mode switches the KVM’s advertised live HID output and verifies it; the saved mode is reapplied on reconnect, including without a video signal. Unsupported or unsuccessful switches show an error.
- **Two fingers:** local pan and anchored pinch zoom, 1×–6×. Settings → Fit to Screen resets the view.
- **Three fingers:** remote vertical scrolling. Position the pointer over the desired panel first. Reverse scrolling defaults to off; direction and sensitivity are configurable. System accessibility/editing gestures can take priority; the remote view also exposes accessibility scroll actions.
- **Round button:** tap for controls; drag to another safe-area corner. Its corner persists across launches and adapts to resizing.
- **Switch connection:** opens a light/dark preview grid with a 0.2-second transition, connection names and a gold outline around the current connection. Previews use the last received frame, are resized to at most 640 pixels and cached locally across launches; unvisited connections show a placeholder. Selecting another connection releases remote input and disconnects the previous stream before starting the selected one. Passwords entered during this app session stay in memory for quick switching and are cleared when closing the connection; persistent passwords still use Keychain.
- **Close connection:** continuous one-second hold; lifting or moving away cancels. Accessibility activation presents a deliberate confirmation.
- **Keyboard:** keeps the system keyboard open beneath the remote canvas. The canvas and floating control resize above the keyboard in portrait and landscape; remote touches keep it open. Tap the red **X** to hide it and restore the full canvas. Committed text uses the selected KVM keymap, with Backspace and Return ordered alongside it. Closing the keyboard preserves accepted input; disconnecting cancels unsent input.
- **Keyboard toolbar:** enabled by default, with a horizontally scrolling row of Ctrl, Alt, Shift, Windows/Command, AltGr, Esc, Tab, arrows, F1–F12, Home/End, Page Up/Down, Insert/Delete, lock keys, Print Screen and Pause. Tap one or more modifiers, then a toolbar key or a letter on the system keyboard; modifiers clear after that command or when the keyboard closes. Toggle **Settings → Keyboard & Type → Show special-key toolbar** to hide it. This preference applies across connections and persists across launches.
- **Type:** exact multiline text with native paste/IME, no automatic punctuation or capitalization. Send closes the editor immediately and continues through the session-owned `/api/hid/print` request. Maximum 16,384 Unicode scalars, no retries or Abort button. An uncertain result retains the draft in memory; check the remote screen before resubmitting. A successful request does not prove that the target application has finished processing all characters.
- **Special keys / Shortcuts:** individual keys and combinations are separate; the sheet waits for balanced down/up transitions to be sent before returning to the screen. Command/Ctrl+V is a remote shortcut; it does not read the phone clipboard.
- **OCR:** selects one frozen frame. Drag a rectangle with one finger, then copy recognized text or retry on that same frame. Cancel/Done returns to live video; rotation cancels selection. Vision runs locally.

Hardware keyboards use USB key identities and the shared native-layout option. OS-reserved combinations remain available through Shortcuts. Pointer hover, clicks and wheel scrolling are supported. Real keyboard/pointer layouts and multi-touch behavior still require the physical acceptance run.

Video continues while the app is inactive but still visible, including the minimize transition and Control Center. Losing focus releases held remote input. Streaming pauses on entering the background and reconnects on returning to the app; audio interruptions alone no longer disconnect video.

Switching connections and returning from the background show the selected connection’s last screenshot, gently blurred and darkened, with a connecting indicator. The preview fades out over 0.2 seconds only after a fresh video frame arrives, and remote input stays blocked until then. Expected foreground reconnection starts immediately without a fabricated network-loss error; genuine connection failures remain visible.

The first connection waits until the gesture guide has finished dismissing before starting authentication, certificate checks, or media. The guide supports Skip/Back/Next and can be replayed in Settings or Connections → More. The guide has coordinated light and dark illustrations with cobalt, magenta, turquoise and lavender accents. It follows System appearance or the Light/Dark selection in Settings. A spacious side-by-side layout adapts to iPad and landscape; large accessibility text scrolls above pinned navigation. Explanations are native labels, without animated touch dots. See [onboarding-artwork.md](onboarding-artwork.md) for bundled image paths and generation prompts. Reduce Motion disables custom transitions, including the floating button’s repeated corner-snap animation.

## Settings coverage

| Desktop capability | Mobile presentation |
| --- | --- |
| Profiles, Keychain, trust | Connection list/editor and approval alert |
| Scale/rotation | Touch viewport, Fit to Screen, rotation selector; fit is the mobile baseline |
| Keyboard/keymap/mapped cadence | Keyboard & Type; default cadence remains 50 ms and does not control HTTP printing |
| Mouse mode/sensitivity/scroll | Mouse section; Absolute default, Trackpad persisted per connection |
| Encoder presets, FPS, bitrate, GOP, JPEG quality, resolution, codec, zero delay, mode | Screen quality, gated by advertised parameters and limits |
| EDID resolution and identity, backup/restore | Display / EDID, explicit apply/restore confirmation |
| Remote playback and microphone | Audio, microphone capability/permission gated |
| USB functions and HID output selection | KVM devices, advertised controls only, disruptive changes confirmed |
| Jiggler interval and schedule | KVM devices, only when advertised |
| OCR language | Text recognition |
| Appearance, diagnostics, restart | View and Connection sections |
| MCP, agent, OmniParser, transcription | Excluded |
| Desktop capture hotkeys, mouse polling, automatic clipboard interception | Replaced by touch ownership/native UIKit event delivery and explicit Type editor |

## Implementation notes

`SessionCore` is the single connection state machine; `SessionController` is the thin macOS subclass that owns desktop services. `DisplaySettingsController` moved into the shared module and is re-exported to preserve desktop callers. `ViewportTransform` is composed with `DisplayGeometry` for both GPU geometry and inverse touch/OCR mapping. Relative movement accumulates fractional deltas and splits packets without replacement coalescing.

UIKit touch sequences directly implement ownership rather than a collection of competing one/two/three-finger recognizers. This lets additional fingers synchronously release dragging, and suppresses all mouse activity until the sequence ends after fingers are removed. Two-finger centroid movement and span changes are applied together. This is an implementation choice within the specified interaction contract.

The Debug simulator build contains a local UI-test fixture behind `ASTEROID_UI_FIXTURE=1`; it cannot be enabled on devices or in Release. It uses the production session, Metal surface and HID queue with a synthetic frame and injected output. Automated tests never send commands to a real KVM.

See [verification.md](verification.md) for results and the remaining physical acceptance matrix.

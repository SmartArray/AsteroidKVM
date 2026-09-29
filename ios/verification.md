# Implementation and verification record

Implementation date: 2026-09-29. Toolchain: Xcode 27.0 (27A266a), macOS 27.0. Minimum deployment target remains iOS/iPadOS 17. WebRTC is still pinned to 153.0.0; the artifact contains both iOS arm64 and arm64/x86_64 Simulator slices. Its downloaded SHA-256 matched the pinned package checksum.

## Changes delivered

- Shared `CometSessionCore` owns authentication, capability discovery, state socket, WebRTC lifecycle, reconnect, ordered input, typing, settings and OCR. The existing desktop `SessionController` subclasses it and retains agent/MCP/transcription composition.
- Shared Metal rendering now supports UIKit scale/color-space handling and a local viewport transform. macOS ScreenCaptureKit code is excluded from iOS compilation.
- `ios/App` provides saved connections, trust/password flows, a persistent Metal surface, touch/keyboard/pointer input, the movable menu, Type, keys/shortcuts, capability-aware settings, display/EDID editing, local OCR, gesture onboarding, notices, audio/lifecycle handling and accessibility actions.
- Shared input preserves accepted typing across sheet dismissal, reports operation-specific completion, accumulates relative deltas, and invalidates stale session/media/OCR callbacks. Mobile preferences decode older profiles as Absolute mode with the existing 50 ms mapped-key interval.
- The project generator emits the app, separate mobile unit/UI test targets, assets and shared scheme. The separate iOS workflow has read-only permissions and does not alter macOS publishing.

## Automated evidence

| Check | Result |
| --- | --- |
| Generic iOS Simulator build, arm64 and x86_64 | Passed |
| Unsigned iOS arm64 device build | Passed |
| macOS Release build (`scripts/build.sh`) | Passed |
| Existing unit suite (`scripts/test.sh --unit`) | 95 tests, 3 environment-dependent skips, 0 failures |
| Geometry, input, desktop surface lifecycle and local protocol regression | Passed except one first-frame timeout in the agent/video test on the first combined run; that test passed on an isolated rerun |
| Local native WebRTC → decoder → Metal test | Passed; VideoToolbox, zero-copy CVPixelBuffer/Metal path observed |
| Mobile contracts | 11 tests passed on each simulator: inverse transforms for every rotation/pixel aspect, anchored zoom/bounds/crops, fractional relative packets, touch ownership transitions/suppression, legacy profile defaults, exact text/keymap/barriers, duplicate protection, cancellation/failure recovery and balanced shortcuts |
| iPhone Simulator UI | 5 tests passed, 0 failures: connections/editor, full guide, large accessibility text, menu, immediate Type dismissal, keys/shortcuts, settings, portrait/landscape, early-release and completed disconnect hold, actual Vision OCR and same-snapshot retry |
| iPad Simulator UI | 5 tests passed, 0 failures: connections/editor, large-text guide, menu, Type, keys/shortcuts, settings, portrait/landscape, Vision OCR/retry; disconnect hold passed after replacing the conflicting custom press handling with a duration-based recognizer |
| Project regeneration | Two consecutive generations produced identical project/scheme hashes |
| Mobile dependency/resource inspection | No CometAgent, desktop session, ScreenCaptureKit, parser scripts/models, or MCP listeners in the mobile build graph/bundle; bundled WebRTC notices remain applicable |

Simulator devices: **iPhone 18 Pro, iOS 27.0**, and **iPad mini (A17 Pro), iPadOS 27.0**. Each final simulator run passed all 16 tests with no skips or runtime warnings. The screenshot set is in `build/screenshots`; XCTest retains named screenshots in its result bundles. Local test result bundles use `/tmp/AsteroidKVM-*.xcresult`. The build scripts do not encode these particular device names and select from installed simulators.

The first Simulator test attempt was blocked by workspace Documents access permissions. Running test products from a temporary directory resolved that. Test screenshots/logs remain local and are not committed. Xcode 27’s optional diagnostic collection was slow; final runs disabled verbose diagnostics, preserving test results and screenshot attachments.

Follow-up credential regression: new and never-remembered connections now skip Keychain access when saving, changing endpoints, or deleting. Disabling a previously remembered password still removes the old credential and reports any removal failure. The added iPhone UI test passed through save, relaunch, endpoint edit, delete, and a second relaunch with the switch off. Both generic Simulator and unsigned device builds passed after this fix; results are in `/tmp/AsteroidKVM-Keychain-Regression.xcresult`.

## Local build artifacts

- `build/AsteroidKVM-iOS-Simulator.zip`: installable Simulator app, both simulator architectures.
- `build/AsteroidKVM-iOS-Unsigned.zip`: unsigned arm64 device app; signing/provisioning is required before physical installation.
- The corresponding `.app` bundles remain in the build paths listed in the setup README.

## Intentional implementation choices

- Shared code stays in `Sources`; the mobile app, asset catalog, Info.plist and tests are under `ios`. The existing root project/generator is the reproducible entry point.
- Touch sequences directly own one-, two-, and three-finger interactions, with a shared testable ownership model. Two-finger centroid/span changes apply pan and pinch together. UIKit’s native long-press recognition implements the exact two-second disconnect threshold; accessibility activation uses confirmation.
- Horizontal touch scrolling and momentum are not synthesized. Three-finger translation produces the existing vertical wheel packets.
- Desktop scale modes and polling controls become a fit-based 1×–6× viewport and UIKit event delivery. Desktop automatic clipboard interception is replaced by the explicit Type editor.
- No signing identity, distribution profile, TestFlight upload, automatic discovery, cloud service or custom shortcut editor was added.

## Physical acceptance — planned, not yet run

No real KVM or physical iOS device was contacted during implementation. Simulator coverage does not establish hardware media performance, firmware compatibility or physical multi-touch ergonomics. Complete this matrix with the user-selected KVM before calling the hardware acceptance finished.

Record: iPhone model/OS, iPad model/OS, KVM model/firmware, target OS/keymap, connection type and external keyboard/pointer models.

- [ ] Sign/install on iPhone and iPad; verify local-network permission allowed/denied, valid/invalid credentials and explicit certificate fingerprint approval.
- [ ] Confirm live video, no-signal display, audio, mute, headset unplug, interruptions, optional microphone permission and forwarding.
- [ ] Absolute targeting at corners/center in all rotations, pixel aspects and zoom levels; Trackpad speed and total movement.
- [ ] Single/double clicks, right-click, double-tap-hold drag; slow/fast 1→2→3 finger changes; cancellation, sheet presentation and rotation leave no held button.
- [ ] Two-finger simultaneous pan/pinch; bounded edges and Fit to Screen; iPad resizing.
- [ ] Three-finger scrolling/sign/sensitivity; VoiceOver and system Zoom/editing interception; accessible scroll actions.
- [ ] External keyboard layouts, modifiers, repeats, reserved shortcuts, native composition, pointer buttons/hover/wheel.
- [ ] Exact multiline/Unicode/pasted Type text, immediate dismissal, no duplicate Send, long request, timeout/uncertain outcome and deliberate draft recovery.
- [ ] Menu corner snapping, two-second disconnect/early cancellation, accessibility confirmation, large text, dark/light appearance and Reduce Motion.
- [ ] Supported encoder, USB/HID, jiggler and EDID controls; confirm/restore disruptive changes on a disposable test target.
- [ ] Frozen-frame OCR, rotated/zoomed crop, no text, retry, copy and cancellation while recognition is running.
- [ ] Network loss/backoff, background/foreground, lock/unlock and closing during a request; no stale input replay or false claim of remote typing cancellation.
- [ ] Older supported iOS/iPadOS versions; no iOS 17 simulator runtime was installed in this workspace.

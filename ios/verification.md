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

## Follow-up mobile interaction changes

- Close connection now takes a continuous one-second hold, including the progress ring and guide text.
- The editor tests credentials through the existing login, discovery, certificate policy and logout APIs. It provides green/red status, success/error haptics, retry/cancellation, and clears stale results on edits. Video and remote input are excluded from this check.
- Initial authentication and media wait for the onboarding cover to finish dismissing. Background/foreground transitions preserve that gate. Animated touch dots have been removed.
- The floating menu animates both the destination corner and drag offset on every release, including a return to the same corner. Its gesture is scoped to the button before positioning it.
- A slow-output regression reproduced lost special-key/shortcut events during sheet dismissal. The sheet now flushes the balanced sequence first, and unblocking the remote surface no longer clears accepted output.
- Reverse scrolling remains off by default, covered by both profile and Settings UI assertions; saved user choices are preserved.

The UI fixtures record actual HID output, exercise local pinch and taps around sheet/guide transitions, and serve a loopback HTTP KVM for success, rejected credentials, token cleanup and delayed-start checks. No real appliance is contacted by these tests.

Follow-up verification covered all **11 mobile contracts and 12 iPhone UI cases**, plus **8 targeted iPad UI cases**, passing across full and focused runs. Generic Simulator and unsigned device builds passed. The key-delivery test failed before the fix and passed afterward with a delayed output transport. The older menu test was updated to wait for key delivery before opening another sheet. Editor automation now dismisses the keyboard explicitly, matching the new Done control, before interacting with the protocol menu or testing.

Evidence: `/tmp/AsteroidKVM-Mobile-Updates-Verified.xcresult` contains the full iPhone run and the initial menu-test timing failure; `/tmp/AsteroidKVM-Mobile-Editor-iPhone.xcresult` and `/tmp/AsteroidKVM-Editor-Focus-iPhone.xcresult` contain the passing focused checks. iPad results are split across `/tmp/AsteroidKVM-Mobile-Updates-iPad.xcresult`, `/tmp/AsteroidKVM-Mobile-Editor-iPad.xcresult`, `/tmp/AsteroidKVM-Editor-Focus-iPad.xcresult` and `/tmp/AsteroidKVM-Editor-Final-iPad.xcresult`; the latter completes the connection-test success/failure coverage after correcting keyboard interactions. Haptic feel, remote USB response, and physical touch ergonomics still require real-device acceptance.

## Persistent keyboard follow-up

The floating menu now includes **Keyboard**. UIKit supplies the system keyboard and local text composition; the remote canvas and movable red **X** follow its safe-area height. Touches on the canvas retain keyboard focus. Dismissal restores the full canvas, and disconnecting exits keyboard mode. Committed text, Backspace and Return share the existing ordered output queue; accepted keyboard input survives resizing, focus changes and a subsequent Type request, while disconnect cancels unsent input.

Verification: **14 mobile contracts** and **11 shared input tests** passed. The persistent-keyboard UI flow passed on **iPhone 17e** and **iPad mini (A17 Pro)** with iOS/iPadOS 27, covering canvas bounds, text and balanced key delivery, remote clicks while typing, portrait/landscape, dismissal and reopening. Existing remote-touch and special-key/shortcut UI checks also passed on iPhone 17e; the Type/settings/menu regression passed on iPhone 18 Pro. Generic Simulator (both architectures) and unsigned arm64 device builds passed.

The original iPhone 18 Pro simulator hid the system keyboard while its Mac hardware keyboard was connected, so on-screen-keyboard verification used iPhone 17e. Its initial run encountered Apple's first-use slide-to-type lesson; automation now dismisses that lesson and waits for keyboard hit targets and rotation layout. Passing evidence is in `/tmp/AsteroidKVM-Keyboard-iPhone-Screens.xcresult` and `/tmp/AsteroidKVM-Keyboard-iPad-Verified.xcresult`; `/tmp/AsteroidKVM-Keyboard-iPhone-Verified.xcresult` includes the contracts and passing touch/special-key regressions alongside that initial keyboard-test failure. Portrait and landscape screenshots are saved as `build/screenshots/ios-keyboard-*.png`. Firmware text mapping, physical keyboard composition and real-KVM typing remain part of physical acceptance.

## Light and dark gesture guide

The guide now bundles three matched light/dark illustration pairs, preserving the cobalt, magenta, turquoise and lavender gesture accents. Light mode uses ivory/lavender surfaces; dark mode uses midnight navy with luminous lavender details. Asset-catalog luminosity variants follow SwiftUI appearance and the existing app preference. Native text, tip cards, navigation, progress and the interactive floating-controls preview use the same adaptive palette. Body/tip text and primary-button labels exceed 5.3:1 calculated contrast in both themes.

The layout uses centered side-by-side content on wide screens and stacked content on phones. Instructional text honors accessibility sizing and scrolls independently of pinned navigation. Decorative labels and preview text have bounded scaling; the largest text sizes use an icon for Back and omit the redundant Next arrow. Reduce Motion remains respected, and no animated gesture dots were reintroduced.

Two focused UI tests passed on each of iPhone 18 Pro and iPad mini (A17 Pro): all four pages in both explicit appearances, the actual appearance value, portrait/landscape navigation, preview interaction, completion, and the largest accessibility text size through the controls page. Screenshots were visually inspected. Evidence: `/tmp/AsteroidKVM-Guide-Verified-iPhone.xcresult` and `/tmp/AsteroidKVM-Guide-Final-iPad.xcresult`, plus `/tmp/AsteroidKVM-Guide-Landscape-iPhone.xcresult` for the final compact-landscape illustration sizing. Generic Simulator and unsigned device builds passed, and both local ZIP artifacts were refreshed. Screenshot copies are under `build/screenshots/ios-guide-*`.

System-toggle verification limitation: on this iOS 27 runtime, both XCUIDevice appearance changes and `simctl ui appearance dark` reported success while UIKit traits and Apple's Settings app remained light. An exploratory live-toggle assertion therefore failed and is not part of the passing checks above. No app workaround was added for this simulator behavior; live system changes still need confirmation on a physical device or another runtime. Explicit app Light/Dark selection is verified.

Image paths, provenance and the built-in generation prompt set are recorded in [onboarding-artwork.md](onboarding-artwork.md).

## First-launch welcome and swipe navigation

A separate persisted `welcomeVersion` gates the app's initial connection screen. The four-page welcome introduces Comet KVM, live video/audio and gestures, keyboard/shortcut/OCR tools, and connection profiles with optional Keychain storage. Completing or skipping persists; Connections → More → Welcome tour replays it without resetting the first-connection gesture lesson. Profile-load errors wait until the welcome is dismissed.

Both onboarding flows share a native SwiftUI page-style TabView, with horizontal swipes, bounded Back/Next navigation, independent vertical scrolling, a VoiceOver-adjustable page indicator, and Reduce Motion support. Pages keep the established light/dark palette. The welcome combines the existing gesture artwork with native vector illustrations, avoiding new image downloads or network requests. A simulator-only Debug flag resets just welcome completion for first-launch tests; it is excluded from device and Release builds.

Verification exercises fresh first launch, forward/backward swipes, first/last page boundaries, Back/Next, completion and Skip persistence after relaunch, replay, both appearances, large accessibility text, landscape, guide preview interaction and delayed connection authentication. Initial runs exposed a transient zero-size layout proposal; illustration frames are now clamped to nonnegative dimensions.

Five iPhone UI cases passed in `/tmp/AsteroidKVM-Welcome-iPhone.xcresult`, and four iPad cases passed in `/tmp/AsteroidKVM-Welcome-iPad.xcresult`, including the loopback-server check that no authentication starts before the gesture guide dismisses. `/tmp/AsteroidKVM-Welcome-Final.xcresult` passed both first-launch persistence and the welcome-to-gesture-guide swipe flow after the layout correction, without the frame warning. Both generic Simulator and unsigned device builds passed; the local ZIP artifacts were refreshed. Visual evidence is saved under `build/screenshots/ios-welcome-*`. No physical KVM was used for this onboarding work.

## Transparent onboarding headers

Both tours now scroll beneath a transparent overlay header, with space reserved for the title and Skip button at the top of each page. The brand/page row scrolls with the content. This avoids a native navigation-bar safe-area interaction that disrupted paging after vertical scrolling. The welcome prompt is now “Swipe to see what’s possible.”

Generic Simulator and unsigned device builds passed. Three focused iPhone UI tests passed in `/tmp/AsteroidKVM-Transparent-Overlay.xcresult`: gesture swiping/vertical scrolling, the first-use guide at the largest accessibility text size, and dark welcome/replay/persistence/large-text navigation. Scrolled screenshots verify both transparent headers. The updated welcome layout was also visually checked on iPad.

## Local build artifacts

- `build/AsteroidKVM-iOS-Simulator.zip`: installable Simulator app, both simulator architectures.
- `build/AsteroidKVM-iOS-Unsigned.zip`: unsigned arm64 device app; signing/provisioning is required before physical installation.
- The corresponding `.app` bundles remain in the build paths listed in the setup README.

## Intentional implementation choices

- Shared code stays in `Sources`; the mobile app, asset catalog, Info.plist and tests are under `ios`. The existing root project/generator is the reproducible entry point.
- Touch sequences directly own one-, two-, and three-finger interactions, with a shared testable ownership model. Two-finger centroid/span changes apply pan and pinch together. UIKit’s native long-press recognition implements the one-second disconnect threshold; accessibility activation uses confirmation.
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
- [ ] Persistent Keyboard: live text, Backspace, Return, keymaps/composition, touch interaction while typing, portrait/landscape resizing, red-X dismissal, repeated opening, and disconnect with pending text.
- [ ] Menu corner snapping, one-second disconnect/early cancellation, accessibility confirmation, large text, dark/light appearance and Reduce Motion.
- [ ] Supported encoder, USB/HID, jiggler and EDID controls; confirm/restore disruptive changes on a disposable test target.
- [ ] Frozen-frame OCR, rotated/zoomed crop, no text, retry, copy and cancellation while recognition is running.
- [ ] Network loss/backoff, background/foreground, lock/unlock and closing during a request; no stale input replay or false claim of remote typing cancellation.
- [ ] Older supported iOS/iPadOS versions; no iOS 17 simulator runtime was installed in this workspace.

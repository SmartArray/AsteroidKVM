# Verification

## Viewer-close crash fix — 2026-10-27

The supplied crash log from October 26 shows an Objective-C exception in CFNetwork task creation, reached through `CometAPI.call` from the session heartbeat during window closure. The API previously allowed calls after `URLSession.invalidateAndCancel()`, and its async `data(for:)` call could suspend between entering the API actor and native task creation.

The API now treats close as terminal and idempotent, rejects late HTTP/WebSocket requests with cancellation, and creates native data tasks synchronously on its actor so creation cannot overlap session invalidation. A cancellation holder handles cancellation before or after task installation. Disconnect cancels the heartbeat immediately, and each awaited status poll checks its connection generation before updating state or starting another request.

Six focused tests pass: requests after close, cancellation of in-flight HTTP requests, 400 request attempts racing closure across 20 transports, two-session disconnect/reconnect isolation, TLS certificate policy, and redirect credential isolation. The universal Release app builds for arm64 and x86_64 and passes strict signature verification. The crash's exact long-running desktop/fullscreen sequence remains a manual check.

## Audio output switching fix — 2026-10-22

An earlier native-test stack sample showed AVAudioEngine restarting inside Core Audio's `AudioDeviceStart`/`HALB_IOThread::_WaitForState`. The current app sample was idle, so it did not capture the user's exact freeze. The old routing implementation had no deadline, allowed cancelled native calls to accumulate, and left related synchronous WebRTC operations and HAL enumeration able to block the main actor.

Switching now disables engine availability to release the previous graph, selects the device, and restores availability while preserving the native route, processing policy, and requested I/O state. The SDK's general `engineState` setter must not be used: it overwrites unexposed native fields. Initial selection runs after peer creation initializes the device list, before SDP starts audio. The caller has a five-second deadline; the native operation stays single-flight until the driver actually returns, and late completion cannot overwrite its timeout/cancellation. Rapid selections coalesce to the latest choice. HAL enumeration, track operations, statistics submission, and peer teardown run off the main actor.

Three driver-stall tests cover timeout, rejection of repeated requests, cancellation, late completion, and recovery. A physical-output test reads `kAudioOutputUnitProperty_CurrentDevice` from the actual engine before startup and verifies its UID after switching. Set `ASTEROID_TEST_AUDIO_OUTPUT_UID` to run it and to exercise saved-device startup in the native tone/video/webhook/WAV regression. USB BY-PM700 and MacBook Pro Speakers passed, including returning to System Default. The BenQ PD2706U output still stalled in the native driver: the test returned `timedOut` after five seconds instead of hanging. This is an unresolved device-specific playback failure, not a successful route. Swift cannot interrupt that OS call; the app rejects further native switches until it finishes.

The final full suite, with `ASTEROID_TEST_AUDIO_OUTPUT_UID=BuiltInSpeakerDevice`, completed 151 tests: 142 passed, 9 opt-in tests skipped, no failures. The universal Release app builds for arm64 and x86_64 and passes `codesign --verify --deep --strict`.

Physical listening, microphone forwarding during a route change, and the user's exact device combination remain manual checks.


## WAV audio recording — 21 October 2026

The local regression suite completed 147 tests with 9 opt-in tests skipped and no failures. Six recording tests exercise real WAV headers and sample contents, PCM16/float input, mono/stereo and interleaved/planar layouts, borrowed-buffer reuse, sample-rate changes and converter draining, stop admission, filename sanitization/start timestamps, collision handling, independent connections, file-creation failures, and bounded buffering. The native generated-tone protocol test also records nonzero PCM while playback is muted and verifies that disconnect finalizes the timestamped WAV before returning.

The universal Release app builds successfully, includes `arm64` and `x86_64` slices in both the executable and WebRTC framework, and passes strict signature verification. These checks use generated media and temporary recording folders; they do not capture a microphone or a user's remote session.

The new native UI test `testAudioRecordingStartStopAndSavedFilename` compiles, but both UI attempts stopped before any test executed: XCTest reported “Timed out while enabling automation mode.” Retrying with test parallelism disabled produced the same runner initialization failure despite an available console session. The latest result bundle is `build/DerivedData/Logs/Test/Test-AsteroidKVM-2026.10.21_21-22-29-+0200.xcresult`. The recording buttons' interactive appearance and start/stop flow remain a manual check; file contents and finalization are verified through the controller and real WebRTC pipeline.

## Settings icons and webhook status control — 21 October 2026

All nine focused `AudioNotificationTests` pass. They now verify that status-bar pausing suppresses delivery, cancels capture before sending, preserves the cooldown and pause across reconnects, and leaves saved settings intact. Explicitly disabling and re-enabling notifications reactivates delivery without bypassing the cooldown.

The expanded native UI test `testAudioToolbarAndNotificationSettings` passes: the button starts hidden, appears active after enabling notifications, switches between active and paused, reflects its pause in Settings, and disappears when notifications are disabled. Screenshot inspection confirms icons on all 14 Settings sections and the blue, compact Webhook control in the bottom-left status bar. Result bundle: `build/DerivedData/Logs/Test/Test-AsteroidKVM-2026.10.21_14-50-14-+0200.xcresult`.

The updated universal Release app builds successfully, includes `arm64` and `x86_64`, and passes strict signature verification.

## Audio output and webhook notifications — 21 October 2026

The local `swift test` suite completed 140 tests with 9 opt-in tests skipped and no failures. Eight notification tests cover PCM activity detection, legacy profiles, URL validation, cooldowns, JPEG encoding, per-controller isolation, delivery failures, and cancellation during capture. The protocol suite also negotiates a generated 440 Hz tone and live H.264 video through the production Janus receiver, verifies delivery to a loopback webhook while playback is muted, and exercises output selection/default fallback without restarting video. Real HTTP checks verify the JSON payload and rejection of redirects and non-2xx responses.

The native UI test `testAudioToolbarAndNotificationSettings` passed, verifying the Audio toolbar picker, the 30-second default, URL validation, alias/cooldown edits, and settings persistence across navigation. Its result bundle is `build/DerivedData/Logs/Test/Test-AsteroidKVM-2026.10.21_13-30-00-+0200.xcresult`.

The universal Release build succeeds, contains both `arm64` and `x86_64` slices in the executable and WebRTC framework, and passes `codesign --verify --deep --strict`. The binary is now WebRTC-SDK 150.7871.01, pinned by URL and checksum for its macOS audio APIs. Physical listening, microphone forwarding with the new audio engine, Bluetooth/aggregate-device hot-plug behavior, and delivery to a user-provided remote webhook remain manual checks; this run used generated media and a loopback endpoint.

## Earlier verification

Verified on 12 September 2026 using Xcode 26.6, macOS SDK 26.5, and an Apple Silicon Mac. The project targets macOS 14 and later. The real Comet was accessed only through the explicitly supplied session file; the token is absent from source, logs, and saved profiles.

## Experimental agent verification

The feature uses the installed Codex CLI **0.154.0**, its existing account, and the real app-server dynamic-tool protocol. It is implemented through [Codex app-server](https://developers.openai.com/codex/app-server); no API credentials or device tokens are copied into the integration.

| Run | Result | Coverage |
| --- | --- | --- |
| Full suite with `COMET_CODEX_E2E=1` and `COMET_E2E_SESSION` | 31 passed, 0 failed; the separately authorized agent hardware task skipped, 50.0 seconds | Real Codex model on a generated scratch screen, fragmented subprocess protocol, startup pause, action pause/resume, manual takeover, native WebRTC → screenshot → HID, repeated decoder timestamps, and all baseline hardware/local checks |
| `COMET_AGENT_HARDWARE_E2E=1` with the supplied session | 1 passed, 0 failed, 46.4 seconds | Real Codex created a NEW unsaved Notepad document, entered a four-line apple poem and a unique marker, then inspected the result; independent Vision OCR confirmed the document |
| Native UI with hardware | 3 passed, 0 failed, 85.6 seconds | Streaming chat, explicit screen-sharing/control opt-in, Pause/Resume in chat and beside video, read-only live-screen tool loop, profile/settings workflow, and native fullscreen without reconnecting |
| Final controller/AppKit check | 6 passed, 0 failed; live-model test explicitly skipped in this targeted run | Emergency release shortcut interrupts automation, including when human capture is already released; pause/resume and startup prompt preservation regressions |

The live poem run used two tool actions and received 2,704 frames. Its screenshot is `test-results/agent-hardware-poem.png`; the visible final line is `COMET APPLES 3235`. The new document was left unsaved and existing Notepad tabs were preserved. Screenshot review and independent OCR supplement the model's completion claim. This verifies a concrete task on this Windows/Comet setup, not general autonomous-task reliability.

The hardware UI agent uses a deterministic Codex protocol subprocess constrained to observation and waits by its launch environment, independently of the prompt. Real Codex inference is verified separately on both the generated desktop and the physical remote machine. The latest combined UI bundle is `build/DerivedData/Logs/Test/Test-CometKVM-2026.09.12_08-48-56-+0200.xcresult`.

Hardware testing revealed repeated decoder timestamps despite continuing frame delivery. The mailbox now assigns each received frame a distinct identity, and automation checks arrival age rather than assuming timestamps uniquely identify frames. A focused test reproduces this condition. Agent snapshots are compressed on demand; they do not add CPU copies to the continuous Metal video path.

Long-running autonomous tasks, alternate Codex versions/providers, Intel runtime, and other remote operating systems remain outside this acceptance run. The integration is intentionally marked experimental. No destructive action, file save, external message, or publication was performed by the agent acceptance task.

## Baseline client verification

| Run | Result | Coverage |
| --- | --- | --- |
| `swift test` | 22 passed, 0 failed; hardware test explicitly skipped without opt-in | Input engine, ordered queue, geometry, actual Keychain, profile secrecy, native Metal, Vision, HTTP/WebSocket protocol, multiple sessions, sleep/wake, and genuine native WebRTC video |
| Final full suite with `COMET_E2E_SESSION` set | 23 passed, 0 failed, 0 skipped, 20.4 seconds | All local tests plus the actual appliance; includes bounded closure with a deliberately stalled HID transport |
| Hardware E2E with typing enabled | 1 passed, 0 failed, 22.3 seconds | Actual authentication, capabilities, HID socket, physical Shift and Return, native Janus/WebRTC, Metal presentation, 38 mapped scalars, German text, and multiline HTTP paste |
| Native Xcode UI automation, including hardware | 2 passed, 0 failed, 0 skipped, 53.3 seconds | Profile creation, separate connection window, unsupported native-typing toggle, Devices/System settings, device-specific certificate approval, live fullscreen video, advancing frame counter, and exactly one media connection before/after |

The local protocol server uses actual loopback HTTP and WebSocket connections. Its video fixture negotiates a genuine native H.264 sender against the production Janus receiver. Tests concerning focus and reconnection substitute only the media lifecycle, with the production AppKit input adapter and network path intact. A fixture is not evidence that every device variant supports an endpoint.

The final combined Xcode UI result bundle is under `build/DerivedData/Logs/Test/Test-CometKVM-2026.09.12_08-07-54-+0200.xcresult`. An earlier hardware fullscreen result and screenshot are under `build/DerivedData/Logs/Test/Test-CometKVM-2026.09.12_07-59-45-+0200.xcresult`. Build products and result bundles are intentionally ignored by Git. Run `./scripts/test.sh --ui-hardware` to execute both UI checks with the supplied session.

## Hardware measurements

The final continuously rendered sample collected 600 received frames and 576 GPU completions at 1920 × 1080 over approximately ten seconds. The earlier typing/OCR verification was a separate run.

| Measurement | Observed |
| --- | ---: |
| Received FPS | 60.45 |
| Presented FPS | 58.04 |
| Bitrate at the sampled interval | 1.808 Mbps |
| Network RTT | 7 ms |
| Last GPU command duration | 0.160 ms |
| Frames replaced before consumption | 4 |
| Counted CPU frame copies | 0 |
| Decoder selected | VideoToolbox |
| Texture path | CVPixelBuffer → CVMetalTextureCache |

The test drives an actual MTKView/Metal renderer at a nominal 16 ms cadence. These results describe this Mac, appliance, network, and mostly static lock-screen image; they are not a moving-video throughput guarantee. The successful typing run measured 60.38 received / 55.56 presented FPS before input and OCR verification. GPU duration and RTT are not glass-to-glass latency. CPU utilization, energy, true input-to-photon latency, and long-duration thermal behavior have not been measured.

The final local native sender sample received 90 frames, presented 89, and measured 28.21 / 27.90 FPS with VideoToolbox and zero CPU copies. The fixture is paced by its generator; its rate is not a decoder capacity benchmark.

## Hardware typing findings

The remote Windows editor used German target layout `de`. Initial burst transmission produced incorrect modifiers despite successful mapped acknowledgments. Fast HTTP paste also corrupted some symbols. The successful hardware run used a 120 ms interval after each mapped event and the firmware's `slow=true` paste mode through production paths, without test-only character delays. The current default is 50 ms and remains configurable per connection; hardware acceptance at this new default has not yet been repeated.

The test checks ordered successful acknowledgments for every scalar, then recognizes unique per-run mapped, paste, and completion markers from the decoded remote video. German `äöüÄÖÜß`, `@`, `€`, brackets, braces, backslash, and pipe were also visually inspected in the returned frame. OCR is not relied upon for exact punctuation equality. Isolating the ASCII markers on separate lines avoids the editor's spelling underlines reducing OCR accuracy.

The hardware screenshots are local artifacts in `test-results/`, including `hardware-typing-verified.png`. To capture a frame on another run, explicitly set `COMET_E2E_CAPTURE_PATH` to a writable PNG path. Captures may contain the remote desktop; they are never produced by default.

## Acceptance coverage and remaining manual checks

| Scenario | Evidence / remaining scope |
| --- | --- |
| Two isolated sessions, focused input only | Production session registry and AppKit adapter against two authenticated loopback sessions; two physical appliances were not available |
| Saved versus unsaved credentials | Actual Keychain save/read/account separation/delete and JSON round-trip tests |
| Fullscreen preserves media ownership and releases input | Production adapter lifecycle test checks releases; hardware UI test verifies native fullscreen geometry, continued live frames, and exactly one media connection. Toolbar hover behavior across displays remains manual |
| Retina, rotation, Fill cropping, mouse/OCR coordinates | Shared transform tests; actual switching between external monitors remains manual |
| Stock physical input and unsupported native typing | Capability-negative fixture plus UI disabled-state assertion; balanced physical keys verified on the patched hardware, not a separate stock installation |
| German mapped typing and stock HTTP paste path | Actual Windows editor, successful daemon replies, returned-video markers, and visual symbol inspection |
| Key repeat, modifier transitions, shortcuts, local Command-V | Input and AppKit tests verify ordering, right-side modifiers, repeat handling, and no leaked Command/V. Target OS Caps Lock and held-key repeat behavior remain manual |
| Video/device settings | Actual capability inventory, native UI placement, source-confirmed mutations, and loopback protocol checks. Real encoder changes, USB reconfiguration, and jiggler scheduling were not applied |
| OCR capture, crop, confinement, and release | Vision recognition and transform/clamp tests; selection implemented in production adapter. Physical edge dragging and pointer behavior across monitors remain manual |
| Network loss, sleep/wake, logout | Loopback session lifecycle and cleanup tests; physical sleep/wake, appliance reboot, and hardware logout were not performed |
| Audio and microphone | Native tracks and explicit microphone permission flow implemented; listening and microphone forwarding remain manual |
| Codec/platform coverage | Real H.264/VideoToolbox on Apple Silicon; Intel runtime, alternate codecs, and long-running sessions remain manual |

System identity editing is intentionally reserved by the specification. HEVC, direct-stream, and FEC transports are explicitly unavailable in this implementation, as documented in [API compatibility](api-compatibility.md).

## Release artifact

`./scripts/build.sh` builds `build/DerivedData/Build/Products/Release/AsteroidKVM.app`. The app executable and embedded WebRTC framework both contain `arm64` and `x86_64` architectures. The locally ad-hoc signed bundle passes `codesign --verify --deep --strict`. Upstream WebRTC notices are included in `Contents/Resources/ThirdPartyNotices.txt`. Developer ID signing and notarization are not part of this local build.

# Verification

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

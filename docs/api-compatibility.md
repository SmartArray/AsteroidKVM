# API compatibility

Inspected on 12 September 2026: GL.iNet's GLKVM source at revision `3e8dd23c4bd638a4650433664cc3b0f3b4d29395`, the test device's publicly served V1.9.1 “Kratos” frontend, and the pinned native WebRTC package. No local Overlook project was present. The connected Rockchip RV1126B appliance reported kvmd 4.82 and uStreamer 6.13. Firmware names do not enable optional capabilities.

The API normally wraps responses as `{"ok":true,"result":...}`. Each connection owns its token, cookie headers, TLS policy, HTTP session, HID WebSocket, and Janus socket. Optional endpoint responses 404, 405, and 501 mean unavailable; authentication and transport errors remain visible.

| Feature | Implemented protocol | Verification |
| --- | --- | --- |
| Authentication | Form `POST /api/auth/login` with `user`/`passwd`; `GET /api/auth/check`; scoped `Token` header and `auth_token` cookie | Refreshed session authenticated on hardware; password login and rejection tested against loopback server |
| Screen approval | `two_step_required`, temporary token, form `POST /api/auth/two_step_complete` until approved or expired | Source confirmed; not exercised on hardware |
| Logout | `POST /api/auth/logout`, then local resource and token cleanup | Source and loopback lifecycle tests; hardware token deliberately retained |
| State and HID | `GET /api/hid`, `/api/hid/keymaps`, `/api/streamer`; persistent `/api/ws?stream=true`; JSON `key`, `mouse_button`, `mouse_move`, `mouse_relative`, `mouse_wheel`, `ping` | Live hardware state and balanced physical Shift/Return; protocol fixtures cover other payloads |
| Native typing | `mapped_text` with one printable Unicode scalar and target keymap; `mapped_text_result` acknowledgment | Hardware advertised `mapped_text:true`; all German test scalars acknowledged and visible in returned video; capability-negative fixture disables the UI |
| Paste | UTF-8 `POST /api/hid/print?keymap=de&limit=N&slow=true`; explicit scalar limit, maximum client limit 16,384 | Hardware German symbols and multiline completion verified; loopback tests verify request count and queue exclusion |
| Video signaling | `/janus/ws`, `janus-protocol`, Janus create/attach, `janus.plugin.ustreamer`, features/watch, offer/answer/start, trickle ICE, keepalive | Genuine local WebRTC sender and real appliance both decoded and presented through Metal |
| Encoder controls | `POST /api/streamer/set_params`; advertised parameters/limits; refreshed `/api/streamer` and state events | Hardware capability reads confirmed; writes inspected and exercised against protocol fixture, without changing appliance encoder settings |
| Frontend configuration | `GET /api/system/get_config`, refresh/merge/`POST /api/system/set_config` preserving unknown fields | Hardware read confirmed; merge behavior tested on loopback server; app presentation preferences remain per connection |
| Audio playback | Remote WebRTC audio track, local mute | Native path implemented; audible playback remains a manual check |
| Microphone | Janus `mic` feature gate, explicit macOS permission, microphone track and renegotiation | Source/native implementation; actual microphone routing remains a manual check |
| USB functions | `GET/POST /api/system/otg_functions`, only returned function flags; refresh after mutation | Hardware returned keyboard, mouse, alternate mouse, CD-ROM, flash, and microphone flags; switching actual USB functions remains manual |
| Device mouse | `GET /api/system/get_param`, `POST /api/system/set_param?absolute_mouse=...`; `/api/hid/set_params` for advertised output modes | Hardware read confirmed; mutation protocol inspected |
| Mouse jiggler | `/api/hid/set_params` for `jiggler` and `jiggler_interval` (1–3,600 seconds); JSON `/api/hid/set_jiggler_schedule` with daily start/end `HH:MM` periods | Interval and schedule advertised by hardware; source confirms mutation contracts; not activated during verification |
| Reboot appliance | `GET /api/upgrade/reboot`, confirmation and reconnection | Source confirmed; real appliance was not rebooted |

The HID `jiggler.enabled` flag reports availability; `jiggler.active` reports current running state. Scheduled activation and manual activation are combined by the daemon. Empty schedule periods disable timed activation. Local mouse enablement, keyboard enablement, sensitivity, scrolling, and polling preferences do not mutate USB descriptors.

## Encoder inventory

The original device frontend supplied these presets; values are kbps and frames. The “Lossless” name is a firmware label, not a mathematical guarantee. Each preset is enabled only when its bitrate and GOP fit the connected device's limits.

| Preset | Bitrate | GOP |
| --- | ---: | ---: |
| Auto | 0 | Unchanged |
| Very Low | 500 | 30 |
| Low | 2,000 | 30 |
| Medium | 5,000 | 60 |
| High | 8,000 | 60 |
| Lossless (firmware preset) | 20,000 | 60 |

The test appliance advertised FPS 0–70, bitrate 0–20,000, GOP 0–240, H.264/H.265, quality, encoder mode, and low-delay control. Its resolution feature was false. JPEG quality uses advertised limits if present, otherwise the inspected validator's 1–100 contract when quality support is explicitly true. Encoder modes `smart` and `normal`, video format `0`/`1`, and `zero_delay` follow the inspected daemon and frontend.

H.264 is supported by the pinned native decoder. H.265 is visibly unavailable because that WebRTC binary does not provide an HEVC decoder. The web client's direct-stream and FEC transport choices require a different media backend and are visibly unavailable. They are not silently mapped to WebRTC. USB identity configuration remains reserved behind `HardwareIdentityProvider`; EDID uses the confirmed display-specific interface described below.

## Primary source references

- [GLKVM authentication implementation](https://github.com/gl-inet/glkvm/blob/3e8dd23c4bd638a4650433664cc3b0f3b4d29395/kvmd/apps/kvmd/api/auth.py)
- [GLKVM HID, paste, and jiggler implementation](https://github.com/gl-inet/glkvm/blob/3e8dd23c4bd638a4650433664cc3b0f3b4d29395/kvmd/apps/kvmd/api/hid.py)
- [GLKVM system configuration and USB functions](https://github.com/gl-inet/glkvm/blob/3e8dd23c4bd638a4650433664cc3b0f3b4d29395/kvmd/apps/kvmd/api/system.py)
- [GLKVM streamer integration](https://github.com/gl-inet/glkvm/blob/3e8dd23c4bd638a4650433664cc3b0f3b4d29395/kvmd/apps/kvmd/server.py)
- [GLKVM encoder validators](https://github.com/gl-inet/glkvm/blob/3e8dd23c4bd638a4650433664cc3b0f3b4d29395/kvmd/validators/kvm.py)
- [GLKVM HID timing implementation](https://github.com/gl-inet/glkvm/blob/3e8dd23c4bd638a4650433664cc3b0f3b4d29395/kvmd/plugins/hid/__init__.py)
- [GLKVM appliance reboot implementation](https://github.com/gl-inet/glkvm/blob/3e8dd23c4bd638a4650433664cc3b0f3b4d29395/kvmd/apps/kvmd/api/upgrade.py)
- [Native WebRTC distribution](https://github.com/stasel/WebRTC/tree/153.0.0)

The companion mapped-text extension is specified in [spec.md](spec.md); it is absent from the inspected public HID source and was confirmed separately through the live capability and acknowledgment contract. No device credentials, private configuration dump, or public frontend bundle is included in this repository.

## EDID configuration

Display settings use the appliance web client's `GET /api/upgrade/get_edid` (`result.edid`, whitespace-separated or contiguous hex) and multipart `POST /api/upgrade/edid` (text field `edid`). `GET /api/upgrade/version` supplies the real Comet `model`; the legacy `/api/info` platform model is not used for mode support. The optional EDID catalog endpoint is not required. Authentication and certificate policy are inherited from the connection; a rejected session is not interpreted as unsupported EDID.

The native codec accepts checksummed EDID 1.3/1.4 documents of 128 or 256 bytes with matching extension counts. Bundled timing profiles are complete 256-byte documents with CTA basic audio, stereo LPCM, speaker allocation, and HDMI vendor data. The preferred modes are 1080p60 (148.5 MHz), 1920×1200 CVT reduced blanking (154 MHz), and 2560×1440 CVT reduced blanking (241.5 MHz). Mode selection uses a known-model allowlist including RM1V2; unknown models do not get speculative timing controls.

Writes are serialized, never automatically retried, and verified by readback. Readback verifies firmware's stored EDID, not the target OS's active desktop mode. Firmware may normalize a single-block EDID internally; restoration submits the exact previously returned document. Local backups contain monitor data only and are stored under `Application Support/CometKVM/EDIDBackups` with a hashed connection/endpoint/certificate key.

Run `COMET_EDID_E2E=1 COMET_E2E_SESSION="$HOME/.cache/qrx/comet-session.json" swift test --filter EDIDHardwareTests` for the opt-in hardware apply/readback/video/restore test. It saves an additional temporary recovery copy before writing and requires readable baseline bytes. The native UI test `testDisplaySettingsNavigationAndDrafts` verifies navigation and unapplied edits without writing EDID.

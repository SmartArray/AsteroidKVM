# README screenshot provenance

These images are captures of the actual application, not generated mockups. Both were inspected before inclusion and contain no connection addresses, account names, or session credentials.

| Asset | Source | What it demonstrates |
| --- | --- | --- |
| `fullscreen.jpg` | Native hardware fullscreen UI test, `Test-CometKVM-2026.09.12_07-59-45-+0200.xcresult`; original attachment `78FDF5AB-8255-4137-B29E-6C1F3484B0EF.png` | Remote Windows display and the native client's compact fullscreen status bar |
| `agent-chat.png` | Passing agent UI test, `Test-CometKVM-2026.09.12_08-48-56-+0200.xcresult`; attachment `882B148A-2FF8-4FC8-AFCB-8916CD0C1E7C.png` | The actual chat UI, screen observations, pause/resume, and completion |

The fullscreen capture was converted from PNG to JPEG at quality 85 to reduce the README download size; its dimensions and content are unchanged. The agent capture is the original PNG. Test bundles and other local screenshots remain ignored by Git.

The chat screenshot uses the deterministic, read-only Codex protocol fixture with live Comet video. It is UI evidence, not a claim that those particular responses came from model inference. Separate real-Codex and physical-computer acceptance results are recorded in [verification](../verification.md).

# README screenshot provenance

These images are captures of the actual application, not generated mockups. The remote-display image was supplied by the user for the README and includes the remote desktop's visible system and network information.

| Asset | Source | What it demonstrates |
| --- | --- | --- |
| `remote-display.png` | User-supplied `images/replacement.png`, moved here without alteration | Remote Windows desktop with a browser and PowerShell, native toolbar controls, and connection status |
| `agent-chat.png` | Passing agent UI test, `Test-CometKVM-2026.09.12_08-48-56-+0200.xcresult`; attachment `882B148A-2FF8-4FC8-AFCB-8916CD0C1E7C.png` | The actual chat UI, screen observations, pause/resume, and completion |

Both captures retain their original PNG content. Test bundles and other local screenshots remain ignored by Git.

The chat screenshot uses the deterministic, read-only Codex protocol fixture with live Comet video. It is UI evidence, not a claim that those particular responses came from model inference. Separate real-Codex and physical-computer acceptance results are recorded in [verification](../verification.md).

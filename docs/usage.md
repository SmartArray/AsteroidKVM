# Comet KVM usage guide

A native macOS client for GL.iNet Comet / GLKVM, built with SwiftUI, AppKit, native WebRTC, Metal, and Apple Vision. Requires macOS 14 or later. The WebRTC dependency is pinned to **153.0.0** and includes Apple Silicon and Intel binaries.

## Build and run

Open **CometKVM.xcodeproj**, select **CometKVM → My Mac**, and run. Xcode resolves the pinned package on the first build. No Homebrew dependencies are required; tests also use the system Python 3.

```sh
./scripts/build.sh
open build/DerivedData/Build/Products/Release/CometKVM.app
```

The generated app is locally ad-hoc signed. Developer ID signing and notarization are separate distribution steps. The checked-in project can be regenerated with `python3 scripts/generate-project.py` after adding source files.

Add a connection using its hostname, scheme, port, and account. Passwords are stored only in memory unless **Remember password in Keychain** is selected. A self-signed certificate requires approval of its SHA-256 fingerprint for that specific host and port. Logout does not delete saved passwords.

For an explicitly supplied, ephemeral test session:

```sh
open build/DerivedData/Build/Products/Release/CometKVM.app --args \
  --session-file "$HOME/.cache/qrx/comet-session.json"
```

The app does not import that file automatically. Its token is never added to saved connection profiles. The app still requires device-specific certificate approval; the file's `insecure` flag is used only by the opt-in hardware test harness.

## Controls

- Click the display to capture remote input. The first click captures; subsequent clicks are forwarded.
- **⌃⌥⌘Escape** releases remote input. **⌃⌘F** toggles native fullscreen.
- Escape cancels OCR selection first, and otherwise reaches the remote computer while captured.
- **⌘Q**, **⌘W**, and **⌘,** remain local. Other captured Command shortcuts go to the remote computer, except enabled **⌘V** paste.
- Use **Keyboard** to choose the target OS keymap, paste, send shortcuts, or enable native-layout typing when the daemon advertises it.
- Use **Display** for advertised encoder controls and local Fit, Fill, Actual Size, and rotation.
- Use **Settings → Devices** for the selected Comet's USB functions, audio, mouse, and keyboard settings.
- **Text Recognition** freezes a received frame and runs OCR on the Mac. Drag within the image; Escape cancels.

## Experimental Codex agent

Open a connected remote display and click **Agent** in its toolbar. Install and sign in to [Codex CLI](https://developers.openai.com/codex/cli) first (`codex login`); the integration is tested with version **0.154.0**. The ordinary KVM client does not require Codex. Agent Settings accepts a custom executable path if automatic detection does not find it.

The chat streams Markdown replies and a visible action history. Choose **Remote permission** before starting:

- **Approve each action** (default): review the full proposed input and target, then choose **Approve This Action** or **Reject and Pause**. Approval applies once to that exact action and expires 60 seconds after the screenshot.
- **Observation only**: screenshots are allowed; every action tool is blocked by the application, regardless of the prompt.
- **Full control**: explicitly grants unreviewed input with the remote user's privileges. This includes potentially destructive actions; model instructions are not an authorization barrier in this mode.

Changing permission stops the current turn. Changing host, port, scheme, account, or certificate identity clears the conversation and restores approval mode. Endpoint edits also discard the old certificate exception. Screenshots older than 60 seconds cannot authorize actions in any mode.

Enable the remote-control/screenshot toggle, enter a task such as “Create a new text document and write a poem about apples,” and press **Send** or **⌘Return**. Screenshots and chat go to your configured Codex provider using your existing account and usage limits. This is not local model inference; device credentials remain inside the KVM client.

**Pause / Resume** stays in the chat header and appears beside the remote video while active. Clicking the remote display takes manual control and pauses the agent. Closing chat, disconnecting, changing input configuration, or sleeping also interrupts automation. **⌃⌥⌘Escape** pauses agents and releases input. Resume starts from a fresh screen and preserves the task, including a prompt paused before Codex finished connecting. **Stop** ends the Codex process; **New Conversation** also clears the visible history.

The agent can observe, click/double-click, press balanced key chords, type, scroll, and wait. Text is sent character by character, so Pause stops further typing; a character already sent to the appliance may finish. It requires live video and absolute mouse mode. Each turn pauses after 150 actions or 15 minutes. Conversations remain in app memory and use ephemeral Codex threads. The app-server dynamic-tool API is experimental and may require adaptation after a Codex upgrade.

Chat storage is limited to 1,000 messages, 64 KiB per message including its ID, and 1 MiB total UTF-8 text/ID data. Exceeding a limit stops the agent; use **New Conversation** to clear history. Model-generated links permit only HTTP/HTTPS and show their destination for confirmation before opening a browser. Local files and custom application schemes are blocked. [Security review and fixes](security.md).

## Tests

```sh
./scripts/test.sh --unit      # CI unit selection: no hardware, GPU, interactive UI, or Codex account
./scripts/test.sh             # Unit, real HTTP/WebSocket, AppKit lifecycle, native WebRTC/Metal, and Vision tests
./scripts/test.sh --video     # Genuine local H.264 sender → Janus signaling → decoder → Metal
./scripts/test.sh --hardware  # Real appliance; requires a valid supplied session
./scripts/test.sh --ui        # Xcode UI automation; requires an unlocked interactive macOS desktop
./scripts/test.sh --ui-hardware # Native UI, agent pause/resume with read-only fixture, and live fullscreen
./scripts/test.sh --agent      # Real Codex model against a generated, isolated screen
# With an unlocked remote Windows desktop; creates a NEW unsaved scratch document:
./scripts/test.sh --agent-hardware
# Only with an empty editor focused on the remote computer and its OS layout set to German:
COMET_E2E_TYPING=1 ./scripts/test.sh --hardware
```

Local protocol tests start a loopback server on a random port. The video E2E uses a genuine native WebRTC sender and production receiver; the fixture implements the Janus envelope. Session tests substitute only media lifecycle when testing focus and reconnection. Hardware tests do not reboot or log out the supplied token. The baseline hardware test does not type text. `COMET_E2E_TYPING=1` writes test lines to the focused remote editor; `--agent-hardware` separately authorizes the real Codex scratch-document task. The UI agent fixture is constrained to screenshots and waits independently of the chat prompt.

See [verification and performance](verification.md) for measured results and outstanding hardware/manual checks, [API compatibility](api-compatibility.md) for endpoint provenance, and [architecture](architecture.md) for ownership and rendering details.

## Current limitations

- HEVC decoding, direct-stream transport, and FEC transport are explicitly unavailable. H.264 is the primary supported Comet path; other negotiated WebRTC codecs may use software decoding.
- Native-layout typing requires the `mapped_text` capability. Dead keys and IME composition should use Paste. The client sends one Unicode scalar per mapped event and does not contain a character-layout translation table.
- Mapped characters are paced at 120 ms after each event because bursts lost USB modifier transitions on the test appliance. Paste uses the daemon's `slow=true` mode for the same reason. Neither path retries text.
- Paste sends UTF-8 and an explicit scalar limit, up to 16,384 scalars. Actual character coverage depends on the daemon's target keymap. Failed or interrupted paste is never automatically retried; already queued device input may finish.
- System identity editing is intentionally reserved, with a provider contract for future preview, validation, apply, and restore operations.

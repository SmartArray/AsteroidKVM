# AsteroidKVM usage guide

A native macOS client for GL.iNet Comet / GLKVM, built with SwiftUI, AppKit, native WebRTC, Metal, and Apple Vision. Requires macOS 14 or later. The WebRTC dependency is pinned to **153.0.0** and includes Apple Silicon and Intel binaries.

## Build and run

Open **AsteroidKVM.xcodeproj**, select **AsteroidKVM → My Mac**, and run. Xcode resolves the pinned package on the first build. No Homebrew dependencies are required; tests also use the system Python 3.

```sh
./scripts/build.sh
open build/DerivedData/Build/Products/Release/AsteroidKVM.app
```

The generated app is locally ad-hoc signed. Developer ID signing and notarization are separate distribution steps. The checked-in project can be regenerated with `python3 scripts/generate-project.py` after adding source files.

Existing CometKVM profiles, remembered passwords, display recovery backups, appearance, and Agent preferences migrate to AsteroidKVM on first launch. The previous files and Keychain entries remain in place until you remove them yourself.

Add a connection using its hostname, scheme, port, and account. Passwords are stored only in memory unless **Remember password in Keychain** is selected. A self-signed certificate requires approval of its SHA-256 fingerprint for that specific host and port. Logout does not delete saved passwords.

For an explicitly supplied, ephemeral test session:

```sh
open build/DerivedData/Build/Products/Release/AsteroidKVM.app --args \
  --session-file "$HOME/.cache/qrx/comet-session.json"
```

The app does not import that file automatically. Its token is never added to saved connection profiles. The app still requires device-specific certificate approval; the file's `insecure` flag is used only by the opt-in hardware test harness.

## Controls

- Activating a connected remote-display window focuses its screen and captures keyboard/mouse input automatically. Initial connection also captures when that window is active. Local dialogs and popovers retain their controls. After explicitly releasing input, click the display or reactivate its window to capture again.
- **⌃⌥⌘Escape** releases remote input. **⌃⌘F** toggles native fullscreen.
- Escape cancels OCR selection first, and otherwise reaches the remote computer while captured.
- **⌘Q**, **⌘W**, and **⌘,** remain local. Other captured Command shortcuts go to the remote computer, except enabled **⌘V** paste.
- Use **Keyboard** to choose the target OS keymap, paste, send shortcuts, or enable native-layout typing when the daemon advertises it.
- Use **Display** for advertised encoder controls and local Fit, Fill, Actual Size, and rotation.
- Use **Settings → Devices** for the selected Comet's USB functions, audio, mouse, and keyboard settings.
- **Text Recognition** freezes a received frame and runs OCR on the Mac. Drag within the image; Escape cancels. In the result dialog, **Cancel** dismisses without changing the clipboard; **Copy & Close** copies the recognized text and dismisses.

## Experimental Codex agent

Open **⋯ beneath the prompt** for agent options. The single-line summary shows the model, thinking level, remote permission, and click-preview state. Use the popover’s **Model** selector to choose an image-capable model reported by your installed Codex, including **GPT-5.6-Luna** when available. **Codex default** follows your Codex configuration. The app remembers your choice without editing Codex's configuration. Changing models stops active work and starts a fresh Codex conversation on the next prompt; visible chat history remains. Use **⋯ → Refresh Models** to reload the catalog after changing your Codex installation or account.

The **Thinking** selector offers the effort levels supported by the selected model, including Luna. **Automatic** keeps the app’s medium effort where supported, otherwise using the model’s supported default. Higher levels can take longer. Your choice is remembered for new chats; switching to a model that does not support it resets to Automatic. Changing the level stops active work and starts a fresh conversation on the next prompt, keeping visible history.

Open a connected remote display and click **Agent** in its toolbar. Install and sign in to [Codex CLI](https://developers.openai.com/codex/cli) first (`codex login`); the integration is tested with version **0.154.0**. The ordinary KVM client does not require Codex. Agent Settings accepts a custom executable path if automatic detection does not find it.

The chat streams Markdown replies and a visible action history. Choose **Remote permission** before starting:

- **Approve each action** (default): review the full proposed input and target, then choose **Approve This Action** or **Reject and Pause**. Approval applies once to that exact action and expires 60 seconds after the screenshot.
- **Observation only**: screenshots are allowed; every action tool is blocked by the application, regardless of the prompt.
- **Full control**: explicitly grants unreviewed input with the remote user's privileges. This includes potentially destructive actions; model instructions are not an authorization barrier in this mode.

Changing permission stops the current turn. Changing host, port, scheme, account, or certificate identity clears the conversation and restores approval mode. Endpoint edits also discard the old certificate exception. Screenshots older than 60 seconds cannot authorize actions in any mode.

**Click preview** is enabled by default. A pulsing purple circle on the remote display marks the proposed click while you review it. Clicks wait for at least one second of preview, including in Full control mode. Use **⋯ beneath the prompt → Show Click Preview** to toggle the checkbox; the preference is remembered. The marker is drawn locally and is excluded from screenshots sent to Codex. Rejecting, pausing, or stopping clears it.

Enable the remote-control/screenshot toggle, enter a task such as “Create a new text document and write a poem about apples,” and press **Send** or **⌘Return**. Screenshots and chat go to your configured Codex provider using your existing account and usage limits. This is not local model inference; device credentials remain inside the KVM client.

**Pause / Resume** stays in the chat header and appears beside the remote video while active. Activating the remote display window takes manual control and pauses the agent. Closing chat, disconnecting, changing input configuration, or sleeping also interrupts automation. **⌃⌥⌘Escape** pauses agents and releases input. Resume starts from a fresh screen and preserves the task, including a prompt paused before Codex finished connecting. **Stop** ends the Codex process; **New Conversation** also clears the visible history.

The agent can observe, click/double-click, press balanced key chords, type, scroll, and wait. Text is sent character by character, so Pause stops further typing; a character already sent to the appliance may finish. It requires live video and absolute mouse mode. Each turn pauses after 150 actions or 15 minutes. Conversations remain in app memory and use ephemeral Codex threads. The app-server dynamic-tool API is experimental and may require adaptation after a Codex upgrade.

Chat storage is limited to 1,000 messages, 64 KiB per message including its ID, and 1 MiB total UTF-8 text/ID data. Exceeding a limit stops the agent; use **New Conversation** to clear history. Model-generated links permit only HTTP/HTTPS and show their destination for confirmation before opening a browser. Local files and custom application schemes are blocked. [Security review and fixes](security.md).

## Live audio transcription

Open **Settings → Transcription** to save an OpenAI API key in Keychain and optionally select the spoken language. The integration uses `gpt-live-transcribe` through OpenAI’s [Realtime transcription API](https://developers.openai.com/api/docs/guides/realtime-transcription). API billing is separate from Codex and ChatGPT subscriptions.

In a remote window, open the **Transcription** toolbar button (caption bubble), then enable **Transcribe remote audio**. The popover also links to the full settings and session transcript. Playback continues normally. The bottom caption strip scrolls toward the newest text; click it to open the complete session history. **Clear** stops transcription and wipes the local history, including pending events. Enable transcription again to begin a fresh provider session.

This version copies AsteroidKVM playback through macOS ScreenCaptureKit because the bundled macOS WebRTC library does not expose an audio-sample callback. Allow macOS screen/system-audio recording permission when prompted. Only AsteroidKVM’s process audio is included; no microphone or other applications are captured, and no screen frames are sent. Keep **Mute remote playback** off and only one remote session connected. Starting another connection, disconnecting, sleeping, muting playback, or changing transcription settings stops transcription and requires an explicit restart.

Audio is transmitted only while enabled and is not saved to disk. Transcript history stays in session memory, with a 4 MiB / 10,000-segment limit; reaching a limit stops transcription rather than silently deleting older text. Network backlog is limited to two seconds of audio and stops on overflow. Changing the target identity clears the transcript.

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
- Native-layout typing requires the `mapped_text` capability. Dead keys compose locally: Option+N then Space types `~`, and Option+N then N composes `ñ`. A local preview shows unfinished text; Escape or losing capture cancels it. Committed text is normalized and must be supported by the target keymap; arbitrary IME characters are not guaranteed. The client sends one Unicode scalar per mapped event and does not contain a character-layout translation table.
- Mapped characters are paced at 120 ms after each event because bursts lost USB modifier transitions on the test appliance. Paste uses the daemon's `slow=true` mode for the same reason. Neither path retries text.
- Paste sends UTF-8 and an explicit scalar limit, up to 16,384 scalars. Actual character coverage depends on the daemon's target keymap. Failed or interrupted paste is never automatically retried; already queued device input may finish.
- System identity editing is intentionally reserved, with a provider contract for future preview, validation, apply, and restore operations.

Native composition can be checked locally with `scripts/test.sh --text-input` on an unlocked Mac. It temporarily selects the German input source and restores it, exercising AppKit through the HID queue with a test window supplying focus. The hardware UI suite additionally checks the local preedit indicator and cancellation on live video without committing remote text.

## Display identity and target resolution

Open **Display → Display Settings…** in a remote window to jump to **Settings → Display** with that Comet selected. The settings show the current EDID preference and actual received video dimensions separately. Rotation, local scaling, and encoder controls remain in the toolbar popover; encoder resolution does not set the target desktop resolution.

Choose a preferred EDID mode: **1920×1080**, **1920×1200** (16:10 laptops), or **2560×1440**, approximately **60 Hz**, on recognized Comet models. These complete progressive timing profiles include basic HDMI audio. Choosing a resolution profile replaces the timing template while retaining the edited monitor identity. Unknown models can read their EDID and edit its identity, but cannot select an unverified timing profile.

Manufacturer ID, hexadecimal product code and numeric serial, manufacture week, and year are editable. **Use Example Identity** fills `DEL`, `0xA034`, `0x3031304C`, week `12`, year `2020`; this is an illustrative identity, not a verified Dell display profile. Identity-only edits preserve the original timing and extension bytes. Week `0` means unspecified; existing EDID 1.4 model-year encoding (`255`) is supported.

Edits remain local until **Apply**. **Discard Changes / Reload** reads the device again. Apply checks for concurrent changes, saves the previous known EDID locally, uploads once, and verifies the stored bytes. **Restore Previous EDID** restores that exact backup, including after reopening the app. Backups are scoped to the connection, endpoint, and certificate pin. If firmware exposes only an empty factory default, its exact bytes cannot be backed up or restored.

Applying EDID can briefly interrupt HDMI video. EDID advertises a preferred mode; the target OS decides whether to adopt it, especially with cloned laptop displays. Asteroid shows received video dimensions independently and never automatically restarts the target. After an interrupted or failed upload, reload before retrying; the upload may already have taken effect.

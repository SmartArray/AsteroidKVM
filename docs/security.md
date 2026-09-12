# Security review and remediation

**Reviewed and remediated:** 2026-09-12. The original review covered the implementation preceding commit `240899f` (the review-document commit after the author/committer rewrite). This document records the six findings, their fixes, verification, and remaining limitations. It is a focused source review with adversarial regression tests, not a security certification.

## Current assessment

All six reported findings have code fixes and regression coverage. Agent control now defaults to **Approve each action**. **Observation only** blocks every action tool in the controller. **Full control** remains an explicit local choice for autonomous work and grants unreviewed input with the remote user's privileges; it does not protect against a model choosing destructive or inappropriate actions.

Credentials remain scoped to the appliance transport and Keychain. Endpoint changes invalidate certificate exceptions and agent context. Untrusted numeric values no longer trap at the identified conversion sites. Agent text and transport queues have resource limits, and chat links cannot invoke local-file or custom application handlers.

| ID | Original severity | Status | Resolution |
| :--- | :--- | :--- | :--- |
| S-01 | High when agent control is enabled | Fixed | Application-enforced permission modes and single-use action approvals |
| S-02 | Medium | Fixed | Exact, bounded numeric conversions and safe numeric formatting |
| S-03 | Medium | Fixed | Target-bound conversations, identity invalidation, and lease checks |
| S-04 | Medium | Fixed | Shared transcript budgets, pipe backpressure, bounded writes, and safe broken-pipe handling |
| S-05 | Low | Fixed | Certificate exceptions cleared before endpoint edits are published or persisted |
| S-06 | Low | Fixed | Web-only chat URL policy and explicit destination confirmation |

## Scope and trust boundaries

The review covered Swift authentication and persistence, HTTP/WebSocket handling, media signaling and frame ownership, input delivery, session lifecycle, agent subprocess handling, chat rendering, build configuration, dependency declarations, tests, and GitHub Actions.

Protected assets include appliance passwords and tokens, screen contents, clipboard text, microphone audio, remote input authority, Codex account access, and application artifacts. Important boundaries are:

- **Mac to appliance:** TLS and endpoint identity protect authentication, signaling, and input. A faulty or malicious appliance can still supply malformed application data.
- **Remote screen to model to input:** screen text is untrusted. Correct coordinates and a fresh image cannot establish whether the meaning of an action is authorized.
- **Application to installed Codex/provider:** screenshots and chat are shared after local consent. The executable and configured provider remain trusted dependencies; the `AgentComputer` interface does not sandbox the executable itself.
- **Pull request to CI:** contributor-controlled code runs in test jobs. Release artifacts are built only on pushes to `main`, after successful tests.

The original review did not test a live prompt-injection attack, audit WebRTC machine code, establish provider retention guarantees, perform a comprehensive CVE or Git-history scan, inspect repository settings, or separately audit existing documentation screenshots. Remediation verification uses local adversarial fixtures, the installed model against a synthetic computer, and the native UI against live Comet video. The UI approval fixture proposes a zero-input wait rather than typing or clicking on the remote machine.

## Findings and fixes

### S-01 — Remote action approval was advisory

**Original issue:** instructions asked the model to request permission before destructive operations, publishing, purchases, and secrets, but any syntactically valid input tool could execute immediately. A fixture demonstrated typing despite a user prompt saying “read only.” This established an enforcement gap; successful prompt injection against a live model was not claimed.

**Fix:** [AgentController](../Sources/CometAgent/AgentController.swift) enforces [local permission modes](../Sources/CometAgent/AgentPolicy.swift). The default holds each immutable action for approval. An approval binds a UUID, exact action, screenshot, and endpoint/account/certificate identity. Approving by UUID cannot substitute new arguments. Parallel proposals and replayed approvals cannot execute. Pause, Stop, rejection, permission changes, identity changes, and expiration invalidate pending approval. Observations expire after 60 seconds, including in full-control mode.

[AgentChatView](../Sources/CometApp/AgentChatView.swift) displays the complete action and target in native UI. It exposes **Approve This Action**, **Reject and Pause**, and the permission picker. Full control has a visible explanation of its authority. Model text cannot change these local permissions. Input ownership is rechecked after asynchronous waits in [SessionAgentComputer](../Sources/CometSession/SessionAgentComputer.swift).

**Regression evidence:** [AgentSecurityTests](../Tests/CometCoreTests/AgentSecurityTests.swift) covers all five action types in observation mode, exact-action approval, substitution attempts, replay, cancellation, target changes, expiration, and old observations in full-control mode. [AgentTests](../Tests/CometCoreTests/AgentTests.swift) exercises approval through the actual stdio subprocess. [CometUITests](../Tests/CometUITests/CometUITests.swift) exercises the production approval button with live video and a harmless wait.

**Limit:** approvals authorize input, not semantic correctness or a guaranteed unchanged remote window. Users must inspect the action and display. Full control intentionally permits unreviewed actions; model instructions remain an additional behavioral defense, not an authorization boundary.

### S-02 — Device-controlled numbers could crash the application

**Original issue:** converting a valid JSON number such as `1e100` to `Int` trapped in `JSONValue.text`. Similar unchecked conversions existed in ICE candidate indices, video controls, and Codex response IDs. This could terminate the whole client; memory corruption or code execution was not demonstrated.

**Fix:** [JSONValue.integer(in:)](../Sources/CometCore/Models.swift) verifies finite values, exact integer representability, and field bounds. Generic numeric text falls back to floating-point formatting instead of a trapping conversion. [Video presets](../Sources/CometCore/VideoControls.swift), numeric/jiggler UI controls, [ICE candidate indices](../Sources/CometMedia/JanusClient.swift), and [Codex response IDs](../Sources/CometAgent/CodexTransport.swift) use checked conversions. Invalid ICE indices fail the media connection; invalid Codex IDs close that subprocess transport.

**Regression evidence:** [SecurityTests](../Tests/CometCoreTests/SecurityTests.swift) covers `1e100`, negative extremes, rounded integer boundaries, fractions, non-finite values, and malformed video bounds. [TransportSecurityTests](../Tests/CometCoreTests/TransportSecurityTests.swift) sends overflowing, fractional, and negative response IDs through actual subprocess pipes and verifies graceful failure.

### S-03 — Editing a target retained its previous agent conversation

**Original issue:** the session and cached agent kept their UUID when a saved connection changed endpoint. Pausing did not discard an existing provider thread, particularly after an idle completed turn. Old instructions and data could therefore carry into a different target.

**Fix:** [ConnectionProfile.agentIdentity](../Sources/CometCore/Models.swift) identifies scheme, normalized host, port, account, and certificate exception using an unambiguous encoded tuple. [SessionController](../Sources/CometSession/SessionController.swift) encapsulates profile mutation and publishes an identity-change callback. [AppModel](../Sources/CometSession/AppModel.swift) uses it to clear the agent, destroy provider context, invalidate approval, and restore review mode, including for idle agents. The controller independently checks identity before reuse and on protocol events; the input adapter checks it against the acquired lease. Old transport callbacks have an independent generation guard. Chat consent resets for the new identity.

**Regression evidence:** tests cover live and persisted endpoint changes, account and certificate changes, unchanged identity during display-only preferences, and replacement of a mutable fixture computer's identity while approval is pending. The latter verifies that subsequent work starts a new provider thread even without a session callback.

### S-04 — Assistant output bypassed transcript bounds

**Original issue:** streamed deltas and completion messages mutated the transcript directly, bypassing its 1,000-message limit. Repeated deltas could grow a single message indefinitely. Complete protocol lines were dispatched to an unbounded main-queue backlog.

**Fix:** [AgentTranscript](../Sources/CometAgent/AgentPolicy.swift) owns all timeline mutations with a 1,000-message limit, 64 KiB per message, and 1 MiB total UTF-8 text/ID budget. Replacement completions and repeated deltas share the same accounting. Exceeding a limit stops control and reports a bounded error; **New Conversation** clears the store.

[CodexTransport](../Sources/CometAgent/CodexTransport.swift) caps the reader buffer at 1 MiB and admits only one complete event to the main queue at a time. Pipe backpressure prevents floods of tiny envelopes from becoming unbounded queued work. Screenshot writes have a separate 8 MiB pending-byte budget. Stale callbacks are rejected after Stop.

A stalled-writer test discovered an additional `SIGPIPE` crash when a child exited during a screenshot write. The input descriptor now uses Darwin's per-descriptor `F_SETNOSIGPIPE`, converting broken-pipe writes into errors. Closing the input handle runs on the serial writer queue so it cannot block the main actor. This uses a descriptor-scoped policy rather than changing signal handling for the entire application; the flag is documented in [Apple's XNU headers](https://github.com/apple/darwin-xnu/blob/main/bsd/sys/fcntl.h).

**Regression evidence:** tests cover unique-message floods, repeated multibyte deltas, oversized completion text, aggregate byte limits, replacement accounting, 10,000 small subprocess events, oversized protocol envelopes, invalid response IDs, and a subprocess that stops reading. The stalled-writer regression verifies the write budget and that Stop returns in under one second without terminating the test process.

**Limit:** these budgets constrain application-retained text and queued protocol work; they are not a whole-process memory quota for Codex, WebRTC, or the operating system.

### S-05 — Certificate approval followed edited endpoints

**Original issue:** a certificate exception approved for A remained in the profile when its host or port changed to B. B could use the same certificate/key without a new endpoint-specific approval. A different certificate still failed, so this was not an arbitrary-certificate bypass.

**Fix:** [ConnectionProfile.securingReplacement(of:)](../Sources/CometCore/Models.swift) clears the exception when scheme, normalized host, or port changes. Both profile persistence and live replacement apply this before saving/publishing the edited profile. Display-name changes and host capitalization alone preserve the intended exception.

**Regression evidence:** [SecurityTests](../Tests/CometCoreTests/SecurityTests.swift) checks persisted and live changes across all endpoint components. [TransportSecurityTests](../Tests/CometCoreTests/TransportSecurityTests.swift) uses a disposable self-signed HTTPS server to verify default rejection, acceptance after explicit fingerprint approval, and rejection of a mismatching fingerprint. No system trust anchor is installed. Real redirects verify same-origin credential retention and rejection of host changes, port changes, and HTTPS downgrades.

**Policy:** the transport deliberately accepts normal system trust or an approved leaf exception. This is not strict pinning that rejects every normally trusted replacement certificate. [Apple's manual trust documentation](https://developer.apple.com/documentation/Foundation/performing-manual-server-trust-authentication) describes the evaluation boundary.

### S-06 — Chat links had no scheme policy

**Original issue:** native Markdown retained `file:` and application-specific links without an opening policy. A local user click could invoke a handler outside the remote-computer task; automatic execution was not demonstrated.

**Fix:** [AgentLinkPolicy](../Sources/CometAgent/AgentPolicy.swift) allows only HTTP/HTTPS URLs with a host and no embedded credentials. The chat intercepts `openURL`, rejects other schemes, and reveals the full destination for confirmation before opening the browser. Rendering never opens links or fetches previews. The opening handler rechecks the policy when the user confirms.

**Regression evidence:** tests parse a misleading Markdown label with a `file:` destination and verify rejection. They also cover JavaScript, SSH, application-specific schemes, credential-bearing web URLs, and accepted HTTP/HTTPS destinations. Native UI builds exercise the production integration; no custom handler is invoked by tests.

## Verification

| Check | Result |
| :--- | :--- |
| `./scripts/test.sh --unit` after final queue cleanup | **37 passed**, 0 failures; same selection used by GitHub Actions |
| `COMET_CODEX_E2E=1 swift test` | 51 discovered; **49 passed**, 2 explicitly opt-in hardware tests skipped, 0 failures |
| Installed Codex vision/action test | Passed against a synthetic in-memory computer; no real remote input |
| Native H.264/WebRTC/Metal and HID integration | Passed through loopback Janus/Comet fixtures; native VideoToolbox path reported zero CPU frame copies |
| `./scripts/test.sh --ui-hardware` | **3 passed**, including live-screen pause/resume, native action approval of a zero-input wait, connection editing, and fullscreen |
| Stalled-writer, event-flood, malformed-ID, and TLS/redirect tests | Passed; included in the final suite and CI selection |
| `./scripts/build.sh` | Universal release build succeeded; arm64/x86_64 and ad-hoc signature verified |
| Workflow and source checks | `actionlint`, Python fixture syntax, local documentation links, and `git diff --check` passed |

The native UI result is `build/DerivedData/Logs/Test/Test-CometKVM-2026.09.12_10-19-14-+0200.xcresult` (local, ignored artifact). An earlier UI run failed during Xcode's initial application launch before reaching the agent assertions; the complete rerun passed. The original numeric crash and stalled-writer SIGPIPE were reproduced before their fixes; their regression tests now pass. Existing real-device poem verification remains historical and was not repeated during this remediation.

## Existing controls and remaining work

- **Credentials:** Keychain items remain scoped to scheme/host/port/account, and profiles cannot encode passwords or tokens. The API uses ephemeral sessions with shared cookie, credential, and cache storage disabled. Logout clears its local token even when revocation fails. The original targeted tracked-file scan found none of the enumerated private-key, GitHub-token, OpenAI-key, or AWS-access-key formats; it was not a complete secret or history audit. `.gitignore` now explicitly excludes `comet-session.json` as well as `*.session.json`.
- **Plain HTTP:** HTTPS remains the default. HTTP is an explicit, warned compatibility option and exposes authentication, input, and signaling to the network path. It has not been removed. Deployments requiring encrypted transport must use HTTPS and may wish to disable HTTP by policy.
- **CLI/provider trust:** the adapter launches the installed executable directly, requests an ephemeral read-only thread, disables configured integrations, and rejects unrelated server requests. Its feature overrides remain version-sensitive. A full capability allowlist/version compatibility gate, independent subprocess sandbox, and provider/local diagnostic-retention guarantees remain follow-up work. A successful installed-model test is interoperability evidence, not proof that every CLI version has identical restrictions.
- **Privacy and interruption:** OCR uses local Vision processing. Microphone forwarding is opt-in and stops with media. The frame mailbox clears on stop. Chat text and typed-text previews intentionally remain visible after Stop until cleared. Already delivered remote input cannot be rolled back.
- **Distribution:** the app remains ad-hoc signed with App Sandbox disabled. Developer ID signing, notarization, Hardened Runtime compatibility/entitlements, and process isolation require separate distribution work. These fixes do not claim to provide an OS sandbox or publisher identity.
- **Dependencies:** WebRTC remains pinned to `153.0.0` and a source revision; its resolved binary package declares a download checksum. Binary provenance, reproducible builds, ongoing upstream security monitoring, and a complete CVE assessment remain separate work. No claim of zero dependency vulnerabilities is made.
- **CI:** the workflow uses `pull_request`, read-only repository permissions, SHA-pinned actions, checkout without persisted credentials, and a push-to-`main` release guard after tests. CI now includes the security regression/TLS fixtures. It does not reference signing or hardware credentials, interpolate PR prose into shell commands, or promote PR artifacts into releases. This follows [GitHub's secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use). Rulesets, required reviews, fork approvals, secret-scanning settings, workflow ownership, and hosted execution have not been audited. ZIP checksums provide integrity checking, not independent publisher authentication.

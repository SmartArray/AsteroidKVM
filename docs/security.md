# Security review

Reviewed on **2026-09-12**, against commit **`1d5c85718a337054fda14ff3b9405a9683080933`**. Source references and findings describe that revision. This review changes documentation only; the findings below remain open.

## Assessment

The client has useful controls around credentials, network redirects, ordered input, and agent interruption. The main security concern is the experimental agent: once granted control, its permitted keyboard and mouse tools can perform sensitive operations without an application-enforced approval. Instructions to the model provide behavioral guidance, but cannot establish an authorization boundary against hostile screen content.

The review also identified a reproducible crash from malformed device data, agent context surviving endpoint changes, and an ineffective transcript size limit. Address these before treating the agent as suitable for unattended operation on sensitive machines.

| ID | Severity | Finding | Evidence |
| :--- | :--- | :--- | :--- |
| S-01 | High, conditional on agent control | Sensitive remote operations rely on model instructions for approval | Production controller exercised with a synthetic tool request |
| S-02 | Medium | Unchecked numeric conversions let device responses terminate the client | Production JSON helper crashed in an isolated subprocess |
| S-03 | Medium | Agent conversation survives a change of remote endpoint | Source trace across profile replacement and agent lifecycle |
| S-04 | Medium | Assistant messages bypass transcript limits | 1,100 synthetic deltas produced 1,101 retained messages |
| S-05 | Low | Certificate exceptions follow edited endpoints | Source trace across profile editing and certificate validation |
| S-06 | Low | Model-generated Markdown permits local and custom URL schemes | Local Markdown parsing retained a `file:` link |

Severity reflects impact and the access required to trigger the issue. “High” here describes potential remote-machine actions after the user enables the agent; it does not mean unauthenticated code execution on the Mac. No live prompt-injection attack or third-party binary exploit was attempted.

## Scope and trust boundaries

The review covered the Swift authentication and persistence code, HTTP/WebSocket handling, media signaling and frame ownership, input delivery, session lifecycle, agent controller and subprocess adapter, chat rendering, build configuration, dependency declarations, tests, and GitHub Actions workflow.

Assets include appliance passwords and tokens, remote display contents, clipboard text, microphone audio, remote keyboard/mouse authority, Codex account access, and distributed application artifacts. Relevant boundaries are:

- **Mac → appliance:** device identity and encryption must protect authentication, signaling, and input. A malicious appliance or a network attacker on an explicitly selected HTTP connection can control protocol responses.
- **Remote screen → model → input:** screen content can be hostile even when the appliance and its TLS connection are legitimate. Valid input coordinates do not establish that an operation is authorized.
- **Application → installed Codex process/provider:** the app intentionally sends screenshots and chat after consent. The installed executable and configured provider are trusted dependencies; the narrow `AgentComputer` interface does not sandbox the executable itself.
- **Pull request → CI:** contributor-controlled code executes in the test job. Build artifacts must come from the trusted branch without exposing signing or hardware credentials to PR jobs.

This was a source review with focused local tests, not a full penetration test or certification. It did not access the real session credential file, send input to hardware, invoke a paid model, inspect provider retention, audit WebRTC machine code, perform a comprehensive CVE assessment, inspect GitHub repository settings, or scan all Git history. Existing screenshots were not subjected to a separate privacy audit.

## Findings

### S-01 — Remote action approval is advisory

**Severity:** High when an enabled agent encounters hostile content. **Status:** Open; confirmed enforcement gap, with prompt-injection exploitability inferred rather than demonstrated against a live model.

**Evidence:** [Agent instructions](../Sources/CometAgent/AgentTypes.swift#L80) ask the model to distrust screen text and request permission before destructive operations, publishing, purchases, and secrets. [Tool parsing](../Sources/CometAgent/AgentTypes.swift#L132) validates syntax, coordinates, key codes, and text length. [Tool execution](../Sources/CometAgent/AgentController.swift#L318) then invokes `computer.perform` without a separate user-approval decision. [Session input](../Sources/CometSession/SessionAgentComputer.swift#L111) allows general key chords and text, including Enter and Tab.

**Trigger and impact:** After the user grants remote control, misleading screen content or a mistaken model decision can produce an otherwise valid click, key chord, or typing operation. These tools can use the remote machine's terminal, send a message, change settings, or approve a dialog with the remote user's privileges. Disabling the local Mac shell does not constrain a terminal operated through the remote display. A fresh screen ID prevents replay of an observation; it does not authorize the meaning of the next action.

**Local reproduction:** A fixture submitted “Read the screen only. Do not type or click.” It then supplied `comet_screen`, followed by a valid `comet_action` typing a harmless marker and newline. The production controller delivered one action to an in-memory computer without an approval step. No real desktop was affected. The same fixture confirmed that Pause rejected subsequent input.

**Recommendation:** Add an explicit observation-only mode enforced by the controller. For controlled execution, represent approval as application state bound to the endpoint and exact action or bounded action batch, and invalidate it on pause, cancellation, or identity changes. General desktop actions cannot be reliably classified as destructive by key-code filtering alone; an optional per-action review mode offers a concrete boundary. Clearly describe unrestricted control as granting the agent the remote user's input authority. Keep the existing model instructions as an additional defense.

**Regression criteria:** Observation-only sessions reject every input tool regardless of prompt or model output. Pending actions cannot execute until approved in trusted local UI. Changed arguments, a different target, and approval replay must fail. Preserve immediate Pause behavior.

### S-02 — Device-controlled numbers can crash the application

**Severity:** Medium. **Status:** Open; reproduced.

**Evidence:** [JSONValue.text](../Sources/CometCore/Models.swift#L65) converts an integral `Double` to `Int` without verifying representability. [Janus error handling](../Sources/CometMedia/JanusClient.swift#L89) passes a device-controlled error code through that helper. Other unchecked conversions include [ICE candidate indices](../Sources/CometMedia/JanusClient.swift#L122), [video preset bounds](../Sources/CometCore/VideoControls.swift#L20), and [Codex response IDs](../Sources/CometAgent/CodexTransport.swift#L167).

**Trigger and impact:** A malicious or faulty appliance can supply a finite JSON number outside the integer range. The conversion traps instead of throwing a recoverable protocol error, terminating the whole client and its other sessions. An attacker on a plaintext connection can also inject such data. This is an availability finding; memory corruption or code execution was not demonstrated.

**Local reproduction:** Decoding the following with the production `JSONValue` and evaluating `value["error"]["code"].text` terminated an isolated subprocess with signal 5:

```json
{"janus":"error","error":{"code":1e100}}
```

The diagnostic was `Double value cannot be converted to Int because the result would be greater than Int.max`. The production Janus error branch uses the same expression. The payload was not delivered to the running application or hardware.

**Recommendation:** Introduce shared checked integer decoding using finite/integral validation and `Int(exactly:)` or `Int32(exactly:)`, followed by field-specific bounds. Format generic numeric text without a trapping integer conversion. Reject malformed protocol fields before updating session/UI state. Avoid comparisons against `Double(Int.max)` alone because floating-point rounding makes that boundary unsafe.

**Regression criteria:** Test values around integer limits, `1e100`, negative candidate indices, fractional IDs, and malformed settings. An invalid message should fail the affected connection gracefully while leaving other sessions operational. Crash cases should run in subprocesses until fixed.

### S-03 — Editing a target retains the previous agent conversation

**Severity:** Medium. **Status:** Open; source-verified, without a live cross-device reproduction.

**Evidence:** [AppModel.agent](../Sources/CometSession/AppModel.swift#L99) caches the controller by session UUID. [Profile replacement](../Sources/CometSession/SessionController.swift#L85) disconnects and updates that same session's endpoint. Disconnection invokes the agent's pause callback, but does not clear its thread. [Pause](../Sources/CometAgent/AgentController.swift#L163) retains conversation state; [begin](../Sources/CometAgent/AgentController.swift#L78) reuses an existing transport and thread. A completed, idle agent is not affected by `pause` at all.

**Trigger and impact:** Use the agent on machine A, then edit that saved connection to point to machine B while retaining its profile ID. After connecting to B, Resume or a follow-up can reuse A's conversation. Old instructions and information can influence input on B, and the model can mix data between targets. Endpoint editing is a user action; this finding does not imply that an appliance can silently rewrite a profile.

**Recommendation:** Bind agent context to immutable connection identity: scheme, normalized host, port, username, and relevant trust identity. On identity change, stop and discard the old provider thread, invalidate all input approvals, and require a new conversation for the new target. Historical messages may remain available in a clearly labeled, separate transcript. Ordinary reconnects to the same identity can retain context if that behavior is explicit.

**Regression criteria:** Start a fixture conversation on A, replace the endpoint with B, and verify that B uses a new thread and cannot resume A's task. Repeat for account and certificate changes. Verify that display-only preference changes do not unnecessarily reset the conversation.

### S-04 — Assistant output bypasses the transcript bound

**Severity:** Medium. **Status:** Open; reproduced.

**Evidence:** [append](../Sources/CometAgent/AgentController.swift#L388) limits the transcript to 1,000 messages, but [assistant delta and completion handling](../Sources/CometAgent/AgentController.swift#L253) writes directly to `messages`. Individual message text also grows without a byte limit. The [transport reader](../Sources/CometAgent/CodexTransport.swift#L88) limits its current byte buffer, but dispatches complete lines to the main queue without an outstanding-work limit.

**Trigger and impact:** A faulty, compromised, or excessively verbose app-server stream can retain arbitrarily many assistant messages or repeatedly grow one message. Many small valid envelopes evade the transport buffer limit. This can exhaust memory or stall the UI, reducing access to Pause. A remote screen alone does not directly emit these protocol events; exploiting it through the model would require influencing model output.

**Local reproduction:** An in-process transport fixture delivered 1,100 small `item/agentMessage/delta` events with unique item IDs. The production controller retained **1,101 messages**, including the user prompt. The probe intentionally stopped before memory pressure or a UI stall.

**Recommendation:** Route all transcript mutations through one bounded store with message-count, per-message byte, and total-byte budgets. Batch streaming updates and add reader backpressure. On resource-limit violations, release agent input and surface a bounded error. Cap pending events independently of individual envelope size.

**Regression criteria:** Verify limits for unique item IDs, repeated deltas to one ID, completion messages, and floods of small envelopes. Confirm that limit enforcement keeps Pause responsive and releases input.

### S-05 — Certificate approval is not reset when the endpoint changes

**Severity:** Low, requiring an endpoint edit and reuse of the previously approved certificate/key. **Status:** Open; source-verified.

**Evidence:** [ProfileEditor](../Sources/CometApp/ConnectionManagerView.swift#L111) edits a copy of the complete profile, including `certificateSHA256`, and saves it without clearing that field when host or port changes. [replaceProfile](../Sources/CometSession/SessionController.swift#L85) adopts the updated object unchanged. [DeviceTransport](../Sources/CometCore/CometAPI.swift#L95) checks a challenge against the profile's current host and port, so the old approval now applies to the edited endpoint.

**Trigger and impact:** Approve an otherwise untrusted certificate for A, then edit the profile to B. If B presents the same certificate and possesses its private key, the client accepts it without a new approval, even though the user approved A. A different certificate still fails, so this is not an arbitrary-certificate bypass. Shared appliance certificates or a copied private key make the distinction relevant.

**Recommendation:** Clear certificate approval whenever scheme, normalized host, or port changes, or persist the approved endpoint alongside the fingerprint and compare both. Explain legitimate certificate reuse through a new endpoint-specific confirmation.

**Regression criteria:** An exception approved for A must not authorize B after editing host or port, even if B uses the same certificate. Unchanged endpoints must retain their intended trust behavior.

**Related policy clarification:** The transport accepts normal system trust before checking the stored fingerprint. It therefore implements a certificate exception, not strict pinning that rejects every replacement certificate. This agrees with the transport's current comment and is not counted as another bypass. If strict pinning is desired, change both the policy and UI wording and test trusted-but-mismatching certificates. Apple's [manual server trust documentation](https://developer.apple.com/documentation/Foundation/performing-manual-server-trust-authentication) describes the trust-evaluation boundary.

### S-06 — Chat links have no scheme policy

**Severity:** Low; requires a local user click and an applicable URL handler. **Status:** Open; parsing reproduced, handler behavior not exercised.

**Evidence:** [AgentMarkdownProse](../Sources/CometApp/AgentChatView.swift#L202) passes model text to `AttributedString(markdown:)` and then SwiftUI `Text` without an `openURL` policy or link-scheme filtering. A local parse of `[Open result](file:///private/tmp/review.txt)` retained the `file:` URL attribute.

**Trigger and impact:** Model output can present a reassuring link label whose destination is a local file or an application-specific URL scheme. If clicked and handled by macOS, this can open local content or invoke another application outside the remote-machine task. The tested parsing behavior does not prove automatic URL opening or code execution; the user must interact with the link, and the destination handler determines its effects.

**Recommendation:** Apply one explicit chat link policy, normally allowing only HTTP/HTTPS with the destination visible. Reject local-file and custom schemes unless a particular integration is deliberately supported and approved. Do not automatically fetch previews of model-generated links.

**Regression criteria:** HTTP/HTTPS links follow the documented policy; `file:`, application-specific schemes, and misleading labels cannot dispatch unexpected local handlers. Rendering a message must never open or fetch its links.

## Existing controls and remaining hardening work

### Credentials and network transport

[PasswordStore](../Sources/CometCore/ProfileStore.swift#L23) uses Keychain items scoped by scheme, host, port, and username. The profile model has no password/token fields; the round-trip and Keychain tests passed. Each [DeviceTransport](../Sources/CometCore/CometAPI.swift#L31) uses an ephemeral session with shared cookies, credentials, and caching disabled. The redirect callback rejects another host, scheme, or port, including an HTTPS downgrade. Authentication failures do not automatically retry mutations, and logout clears the API's token even if revocation fails.

HTTPS is the default, but [HTTP is selectable with a warning](../Sources/CometApp/ConnectionManagerView.swift#L125), and [ATS permits arbitrary loads](../Resources/Info.plist). Selecting HTTP exposes passwords, tokens, input, and signaling to the network path. This is an explicit compatibility tradeoff, not a newly discovered silent downgrade. Consider a persistent insecure-connection indicator and a policy to disable HTTP for sensitive deployments. Certificate and redirect behavior still need dedicated TLS and redirect integration tests; the current authentication fixtures use loopback HTTP.

A targeted scan of tracked text found no private-key blocks, GitHub token formats, OpenAI key formats, or AWS access-key IDs. This is not a general secret-scanner result or a history audit. The real session file remained outside the review. Also, `.gitignore` ignores `*.session.json` but does **not** match the hardware filename `comet-session.json`; adding that explicit name would reduce accidental commits if someone copies the file into the repository.

### Agent and local privacy

The UI [discloses screenshot/chat transmission and requires consent before Send](../Sources/CometApp/AgentChatView.swift#L76). Opening chat alone does not start the agent. `AgentComputer` exposes pixels and bounded input, without an appliance credential API. [CodexTransport](../Sources/CometAgent/CodexTransport.swift#L49) launches an executable with an argument array rather than interpolating prompts into a shell command. The controller rejects unrelated server requests and disables configured MCP servers for its thread.

Those configuration overrides are a denylist against an independently installed executable and experimental protocol. The review did not establish a complete capability allowlist for every supported CLI version, OS-level isolation of the subprocess, or provider/local diagnostic retention. Add a version/capability compatibility check and fail closed when required restrictions cannot be confirmed. An empty working directory and a thread's `read-only` sandbox setting are not evidence that the entire subprocess cannot access the user's files or inherited environment.

Pause invalidates input ownership before waiting for model interruption; the local tests verified this. Fresh screen IDs, geometry checks, bounded typing, a 150-action limit, and a 15-minute watchdog reduce operational risk. They do not make completed input reversible. Consider binding observations to an age limit as well as an ID: the adapter checks whether video is live, but an old model observation can remain actionable while newer frames arrive.

OCR runs through local Vision processing. Microphone access is requested on demand and forwarding is stopped with the media session. The media mailbox clears on stop. Chat history intentionally survives Stop, and typed text previews remain in the transcript; users should understand that stopping control is not erasing the conversation.

### Application and dependency distribution

[Build configuration](../scripts/generate-project.py#L156) disables App Sandbox and uses ad-hoc signing. The existing release app reported `Signature=adhoc`, no TeamIdentifier, and flags `0x2(adhoc)`, without the hardened-runtime flag. This is documented development distribution, but provides less containment and publisher assurance than a hardened, Developer ID-signed release. Investigate isolating media decoding and the agent adapter where practical, and enable Hardened Runtime with narrowly justified exceptions before public signed distribution. Apple documents [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) and [notarization requirements](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).

WebRTC is fixed to `153.0.0` in [Package.swift](../Package.swift), with a source revision in [Package.resolved](../Package.resolved). Its locally resolved package declares a binary download checksum. These controls constrain dependency substitution but do not prove that the binary is vulnerability-free or reproducibly built. Track upstream security fixes and record binary provenance; no claim about current CVE exposure is made here.

### GitHub Actions

The [workflow](../.github/workflows/macos.yml) uses `pull_request`, read-only repository permissions, SHA-pinned actions, and checkout without persisted credentials. It does not reference repository secrets or interpolate PR titles/bodies into shell commands. The release job requires passing unit tests and an explicit `push` to `refs/heads/main`. PR artifacts are not promoted into releases, and no shared build cache is configured. These choices align with GitHub's [secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use).

The ZIP preserves bundle permissions and symlinks. The checksum verifies downloaded bytes but is not an independent publisher signature when distributed beside the same artifact. Before adding signing credentials, keep them confined to a protected release job. Repository rulesets, required reviews, fork-workflow approval settings, secret-scanning settings, and the actual hosted execution were not inspected. Consider ownership review for workflow changes and automated dependency/action update monitoring.

## Validation performed

| Check | Result and limits |
| :--- | :--- |
| `./scripts/test.sh --unit` | 18 tests passed, 0 failures; isolated Keychain item and deterministic subprocess fixtures |
| Authentication/session-isolation and failed-authentication/oversize-paste protocol tests | 2 tests passed, 0 failures; local HTTP fixture only |
| Production controller probe | Unauthorized-by-prompt fixture typing reached the in-memory computer; Pause blocked subsequent input |
| Production transcript probe | 1,101 retained messages after 1,100 small assistant deltas |
| Production JSON probe | `1e100` numeric error field caused an isolated Swift integer-conversion trap |
| Markdown attribute probe | `file:` destination survived parsing; no URL handler invoked |
| `actionlint .github/workflows/macos.yml` | Passed |
| Existing release signature inspection | Ad-hoc signature, no TeamIdentifier or hardened-runtime flag |
| Targeted tracked-text secret-format scan | No matches for the four enumerated formats; exclusions and limits noted above |

The temporary probes compiled the repository's actual `CometCore` and `CometAgent` sources and used synthetic inputs. They were not added to the production test suite. Passing existing tests does not close the findings: those tests do not assert the missing security properties.

## Remediation order

1. Establish application-enforced agent permissions and approval behavior, then add adversarial regression coverage for S-01.
2. Remove trapping numeric conversions at all protocol boundaries and verify graceful failures for S-02.
3. Bind conversation state and certificate exceptions to endpoint identity for S-03 and S-05.
4. Bound streamed transcript storage and queued events for S-04; restrict chat link handling for S-06.
5. Add TLS/redirect integration tests and verify CLI capability restrictions. Address release signing, containment, dependency provenance, and repository protections as distribution requirements.

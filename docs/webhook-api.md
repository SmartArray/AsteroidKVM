# Audio notification webhook API

This specification describes the version 1 events sent by AsteroidKVM. A receiver needs one HTTP endpoint that accepts JSON, validates the included JPEG, and acknowledges receipt. The request contract below matches the current app; the proposed route, URL token, and receiver storage policy are conventions you can adopt when building your service.

- [OpenAPI 3.1.1 definition](webhook/openapi.yaml)
- [Standalone JSON Schema](webhook/audio-detected.schema.json)
- [Complete example request with a valid JPEG](webhook/audio-detected.example.json)
- [Configure notifications in AsteroidKVM](usage.md#audio-output-and-notifications)

Keep the files in `docs/webhook/` together: the OpenAPI definition references the schema and example by relative path. The schema uses JSON Schema Draft 2020-12, as supported by [OpenAPI 3.1.1](https://spec.openapis.org/oas/v3.1.1.html#schema-object).

## Endpoint and authentication

Suggested service endpoint:

```http
POST /webhooks/asteroidkvm?token=YOUR_SECRET_TOKEN
Content-Type: application/json
```

Enter its complete URL in **Settings → Notifications → Webhook URL**, for example:

```text
https://notifications.example.com/webhooks/asteroidkvm?token=YOUR_SECRET_TOKEN
```

AsteroidKVM posts to the exact configured endpoint; it does not append a route or token. Your service can choose a different path or query parameter. The OpenAPI definition uses the route above and requires a `token` query parameter as the proposed receiver authentication scheme.

The current sender has no configurable `Authorization` header, HMAC signature, client certificate, or webhook challenge handshake. It does not forward the KVM's credentials or cookies. Use a separate, randomly generated webhook secret in the URL; associate it with the receiving account or integration. Authenticate that secret before trusting any identity fields in the payload. Redact the token from proxy and application logs.

Use HTTPS for a deployed service. HTTP is accepted for local development. HTTPS uses normal system certificate validation; a KVM certificate exception does not apply to the webhook service. URLs containing embedded HTTP credentials (`user:password@host`) or fragments (`#...`) are rejected by the app. All redirects are rejected, including HTTP-to-HTTPS and trailing-slash redirects, so configure the final URL directly.

## Test notifications

**Settings → Notifications → Send Test Notification** posts to the URL currently entered in the form, including its secret token, even before settings are saved. It works with notifications disabled or the KVM disconnected and does not change the audio detection cooldown or pause state.

Tests use the same version 1 `audio_detected` contract and authentication as normal notifications. They contain the connection ID, name, and entered alias, with `message` set to `Test notification from <alias or name>`, `audioLevel: 0`, and a valid 640 × 360 JPEG test card instead of a live screenshot. No extra endpoint or receiver changes are required. Deliver these as ordinary notifications so users can check the full receiver workflow.

The app reports acceptance only after an HTTP 2xx response. HTTP 401/403 reports authentication rejection and asks the user to check the URL's secret token. Network failures, other non-2xx responses, and redirects report failure. Acceptance confirms the receiver accepted the request; it cannot verify a downstream notification banner or prove that a custom receiver enforces authentication.

## Request body

Each request contains one event. It is UTF-8 JSON, with a base64 JPEG embedded in the object. JSON property order is unspecified. The following display example abbreviates the image; use the linked example file for an executable request.

```json
{
  "version": 1,
  "event": "audio_detected",
  "timestamp": "2026-10-21T12:00:00Z",
  "message": "Audio detected on Build Mac",
  "kvm": {
    "id": "D7A9132D-C2DF-4688-B026-186DA77D973D",
    "name": "Office KVM",
    "alias": "Build Mac"
  },
  "audioLevel": 0.12,
  "screenshot": {
    "mimeType": "image/jpeg",
    "base64": "<base64-encoded JPEG bytes>",
    "width": 1600,
    "height": 900
  }
}
```

All fields below are required and non-null. Receivers should tolerate unknown additional fields to allow compatible extensions.

| Field | Type | Meaning |
| --- | --- | --- |
| `version` | integer | Payload version; currently `1`. It is independent of the app's version. |
| `event` | string | Currently always `audio_detected`. |
| `timestamp` | string, date-time | Detection/admission time on the sender's wall clock, recorded before JPEG encoding and the HTTP request. Currently UTC ISO 8601 with whole seconds, such as `2026-10-21T12:00:00Z`. Accept valid date-time strings with fractional seconds too. |
| `message` | string | Display text: `Audio detected on ` (or `Test notification from ` for manual tests) followed by the nonempty alias, or the connection name when no alias is set. Treat it as plain text. |
| `kvm.id` | string, UUID | UUID of the saved AsteroidKVM connection profile. This is not an appliance serial number or an event ID. Accept either UUID letter case. |
| `kvm.name` | string | User-assigned connection name. Mutable and not necessarily unique. |
| `kvm.alias` | string | Optional notification alias, with surrounding whitespace trimmed. The field is always present; an unset alias is `""`, not `null`. |
| `audioLevel` | number | Normalized decoded-audio level in `0…1`. Actual triggered notifications have a positive level. See detection semantics below. |
| `screenshot.mimeType` | string | Always `image/jpeg`. |
| `screenshot.base64` | string | Standard padded base64 of the JPEG bytes, without line breaks or a `data:` URL prefix. It is not base64url. |
| `screenshot.width` | integer | Positive width of the encoded JPEG, in pixels. |
| `screenshot.height` | integer | Positive height of the encoded JPEG, in pixels. |

Use the authenticated account/integration together with `kvm.id` to associate events with a saved connection. Names and aliases can change. Saving the same physical KVM in another profile or on another Mac can produce a different UUID; copying a saved profile can preserve its UUID. The payload does not identify a Mac installation, and changing a profile's destination can reuse its existing UUID.

No raw audio, KVM hostname, credentials, output-device ID, mute state, cooldown, or threshold setting is included.

## Screenshot handling

The screenshot is mandatory. Automatic audio notifications send only when AsteroidKVM has a decoded KVM video frame received less than three seconds earlier. The screenshot contains that remote frame, rather than the Mac desktop or application chrome. It is not guaranteed to capture the exact instant of the sound, and no separate frame timestamp is supplied. Manual tests use the generated test card described above.

The current encoder preserves the full image and aspect ratio, downsizes toward a 1,600-pixel longest side without upscaling, and uses JPEG quality `0.8`. Integer image bounds can round dimensions up; the reported width and height are the actual encoded dimensions. JPEG byte size varies with the image. The sender does not impose a fixed request-byte limit.

For a first receiver implementation, a configurable **8 MiB JSON body limit** and **2,048 pixels per image dimension** are reasonable service policies for current output. These are receiver recommendations, not additional sender guarantees. Base64 adds roughly one third to the JPEG byte size. Review these limits if future sender versions change the encoder.

Decode base64 strictly, verify that the decoded data is a valid JPEG, and check that its decoded dimensions match the declared fields and your image limits. JSON Schema validation alone does not verify the JPEG: OpenAPI treats `contentEncoding` and `contentMediaType` as [annotations requiring additional validation](https://spec.openapis.org/oas/v3.1.1.html#non-validating-constraint-keywords). Store screenshots privately under server-generated identifiers, and choose an explicit retention period. Avoid logging the full request body.

## Detection and delivery semantics

| Behavior | Current implementation |
| --- | --- |
| Activity measurement | Highest decoded-buffer RMS level observed since the previous poll, across the remote track's channels; polls occur approximately once per second. This is a peak of buffer RMS measurements, not peak sample amplitude or an average over the whole polling interval. |
| Local playback mute | Detection runs before playback gain, so muting remote playback does not disable notifications. |
| Status-bar control | When notifications are enabled, the remote window shows a blue **Audio Notification Webhook** button. Clicking it pauses delivery and turns it gray; clicking again resumes. The pause is per session and survives normal reconnects without resetting the cooldown. Restarting the app or explicitly disabling and re-enabling notifications activates delivery again. Disabled notifications hide the button. |
| Threshold | Default `−40 dBFS`, configurable from `−60` to `−10`. A positive level qualifies when `20 × log10(audioLevel) >= threshold`. At the default threshold, `0.01` qualifies. This is a digital signal level, not a measured sound pressure level. |
| Cooldown | Default `30` seconds; configurable from `1` to `86,400`. Measured from admission of an attempt, before screenshot encoding and delivery. Failed encoding or HTTP attempts also consume the cooldown. |
| Continuous audio | Can produce another event after each cooldown if qualifying audio and a fresh video frame are available. No silence-to-sound transition is required. |
| Suppressed activity | Activity during a pause, cooldown, or an in-flight delivery is not queued for later replay. No event is sent just because delivery resumes or the cooldown expires. |
| Concurrency | At most one in-flight delivery per active notification controller. Different KVMs/controllers can send concurrently. |
| Cooldown persistence | Normal reconnects retain the cooldown while the controller and connection identity are retained. It is in memory, not persisted across app restarts or controller recreation. It is not a service-wide rate limit. |
| Network timeout | The HTTP request is configured with a 10-second timeout. Treat this as a request timeout setting, not a guaranteed end-to-end deadline. Return a short acknowledgement promptly; target under two seconds. |
| Success | Any HTTP status in `200…299`; the response body is ignored. |
| Failure | Network errors, redirects, and non-`2xx` responses are failures. Error response bodies are not displayed by the app; an HTTP failure is shown by status code. |
| Retries | No application-level retry, retry queue, or replay of the failed event. `Retry-After` does not alter the sender's cooldown. A later qualifying sound can create a new event. |
| Cancellation | Disconnect, sleep, pausing from the status bar, disabling notifications, or relevant profile/settings changes cancel pending work. A request already transmitted may still be processed by the service. |

Delivery is best effort. There is no event UUID, sequence number, idempotency header, acknowledgement handshake, or delivery guarantee. A timestamp has only second precision and is supplied by the client's clock, so it is not a unique key or proof of freshness. Do not use `kvm.id` as an event deduplication key: that would discard subsequent legitimate notifications.

Assign your own receipt ID and server receipt timestamp. If you need duplicate suppression for proxy/manual replays, use a short-lived hash of the exact request body scoped to the authenticated integration. Identical payloads cannot be distinguished reliably from legitimate repeats in version 1. Do not promise exactly-once processing or strict ordering across clients.

## Receiver responses

The following statuses are proposed service behavior. AsteroidKVM only distinguishes `2xx` success from failure and does not require any response JSON.

| Status | When your service should return it |
| --- | --- |
| `202 Accepted` | Recommended: valid event has been durably stored or queued for processing. An empty body is sufficient. |
| `204 No Content` | Valid event has been handled synchronously. |
| `200 OK` | Also compatible if your service returns a synchronous result. |
| `400 Bad Request` | Malformed JSON, invalid/missing fields, unsupported payload version/event, invalid base64/JPEG, or inconsistent dimensions. |
| `401 Unauthorized` | Missing or invalid webhook token. |
| `413 Content Too Large` | Request exceeds your configured body limit. |
| `415 Unsupported Media Type` | Request is not JSON. |
| `429 Too Many Requests` | Your service's own rate limit is exceeded. The dropped event will not be retried by AsteroidKVM. |
| `503 Service Unavailable` | Your service cannot accept/store the event. The event will not be retried by AsteroidKVM. |

A useful processing sequence is:

1. Enforce a body limit and authenticate the URL token.
2. Parse JSON and validate it against the schema. Enable UUID and date-time format checks in your validator.
3. Decode and validate the JPEG, including its dimensions and byte/pixel limits.
4. Persist or durably enqueue the event and image with the authenticated integration, a server receipt ID, and server receipt time.
5. Return `202` promptly. Process downstream push/email/chat delivery asynchronously with your service's own retry policy.

Do not acknowledge success before durable acceptance if losing a notification would be a problem: the app cannot replay it. Do not redirect to sign-in pages or canonical URLs. No browser CORS setup or verification GET is required by this native sender.

## Send a sample request

From the repository root, replace the host and example token with your service values:

```sh
curl --fail-with-body --include \
  --request POST \
  --header 'Content-Type: application/json' \
  --data-binary @docs/webhook/audio-detected.example.json \
  'https://notifications.example.com/webhooks/asteroidkvm?token=REPLACE_ME'
```

The example file contains a valid 1 × 1 JPEG and a fixed example timestamp. It tests request acceptance and image decoding; refresh the timestamp if your service adds an age policy. A typical response is simply:

```http
HTTP/1.1 202 Accepted
Content-Length: 0
```

Receiver acceptance checks: accept the sample and an empty alias; accept extra fields; reject a missing screenshot, invalid token, invalid JPEG, or mismatched dimensions; accept two events for the same KVM with different timestamps; return a direct `2xx` without waiting for downstream notification delivery.

## Contract sources

This spec documents the implementation in [AudioNotifications.swift](../Sources/CometCore/AudioNotifications.swift), [AudioNotificationController.swift](../Sources/CometSession/AudioNotificationController.swift), and [AudioActivityMonitor.swift](../Sources/CometMedia/AudioActivityMonitor.swift). HTTP behavior and muted-audio delivery are exercised in [ProtocolE2ETests.swift](../Tests/CometCoreTests/ProtocolE2ETests.swift). The service route, token convention, receipt storage, and downstream processing described here do not require changes to the current app.

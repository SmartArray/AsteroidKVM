# Per-device MCP servers

AsteroidKVM exposes one authenticated localhost MCP endpoint per saved connection. Each endpoint is permanently bound to that connection's UUID and has a separate Keychain token, port, clients, control owner, and in-memory activity history. It cannot switch devices or fall back to the focused window. Servers run inside the app process; they are not separate crash-isolated processes.

## Setup

1. Open **Settings → MCP** and choose a connection.
2. Turn on **Enable MCP for this device**. New configurations choose an unused device port starting at 9101. You can apply another port between 1024 and 65535.
3. Leave **Allow keyboard and mouse control** off for observation-only access, or turn it on to grant input access.
4. Use **Copy MCP Configuration** and add the resulting entry to a client that supports Streamable HTTP and custom Authorization headers. The copied configuration includes a secret. The app keeps its token in Keychain, not in the profile file.
5. Keep AsteroidKVM running and connect the KVM normally. Endpoints can report disconnected status, but screenshots, OCR, and input require live video. Enabling MCP does not automatically connect to the appliance.

Example structure (use the app's actual copied values):

```json
{
  "mcpServers": {
    "asteroid-device-id": {
      "url": "http://127.0.0.1:9101/mcp",
      "headers": { "Authorization": "Bearer YOUR_DEVICE_TOKEN" }
    }
  }
}
```

Different clients may use different configuration formats. The endpoint and Authorization header are the connection details. This release uses pre-shared tokens for local access; it does not implement OAuth discovery or expose a LAN listener.

## Tools

| Tool | Arguments and behavior |
| --- | --- |
| `get_device` | Device ID, name, status, control permission, native typing capability and interval. |
| `get_screen` | Optional `region: {x,y,width,height}`. Returns JPEG plus frame ID, full-screen dimensions, crop origin, capture time and age. |
| `read_text` | Optional region and frame ID. Returns text, confidence and bounding boxes in full-screen source coordinates. With a frame ID, OCR uses that retained screenshot frame. |
| `wait_for_change` | Frame ID, optional region and `timeoutMs` (0–30000, default 10000). Compares downsampled pixels, then returns a fresh image and `changed`. Small or subtle changes may not exceed the threshold. |
| `type_text` | Text of 1–1000 Unicode scalars. Uses the target layout and configured interval, with firmware paste fallback. Newline and tab are supported. |
| `press_keys` | 1–5 distinct USB key codes. Ctrl+Alt+Delete is `["ControlLeft","AltLeft","Delete"]`; keys are pressed in order and released in reverse. |
| `click` | `x,y`, optional `button` (left/right/middle) and `count` (1/2). |
| `scroll` | `delta` from -10 to 10; positive scrolls down. Set `horizontal: true` for horizontal scrolling, with positive right. |
| `drag` | `x,y,toX,toY`, optional `durationMs` from 100 to 5000 (default 500). Uses the left mouse button. |
| `stop` | Cancels this client's operation and releases its control. Does not interrupt another client or the built-in agent. |

All input tools require `frameId` and a unique `actionId`, and accept `returnScreen: true`. Get a new screen after every action unless the action returned one. Input uses physical key events or the existing firmware text path; it does not access the remote OS, shell, clipboard contents, credentials, or power controls.

Images are native-resolution **unrotated source pixels**, with a top-left origin. UI zoom and rotation do not change MCP coordinates. A cropped image retains the full-screen coordinate system: add its region's x/y offsets to image-local coordinates before clicking. OCR bounding boxes already include these offsets.

A frame ID is scoped to the MCP client that received it. The latest observation replaces that client's previous one. Input rejects missing IDs, changed source dimensions, observations older than 30 seconds, video older than 3 seconds, disconnected devices, and no-signal states. A recent frame cannot guarantee that the target UI has not changed; inspect action results before proceeding.

## Control and recovery

Only one controller can own a device's input: an external MCP client or the built-in agent. Observation-only requests do not acquire control. Another device remains independent.

- **Stop Automation** in the remote toolbar or MCP settings cancels input and pauses MCP control. Resume explicitly in MCP settings. Clicking back into the remote display takes manual control and pauses an existing MCP controller.
- **⌃⌥⌘Esc** while the app is active releases input. The application menu command stops all devices; the remote display's shortcut and toolbar stop its device.
- Ownership expires after 30 seconds without requests while idle. An operation is cancelled after 120 seconds. Very long text at slow intervals can therefore execute only partially.
- Clients expire after five idle minutes. HTTP `DELETE` ends a client session and releases input. MCP cancellation notifications cancel the matching request.
- A dropped HTTP connection alone does not mean cancellation: the request may have reached the device. Use `actionId` to retry the identical request without replaying input, or reconnect and inspect the screen if the MCP session has expired.
- Action IDs are remembered for that MCP session, including failures and cancellations, up to 1024 actions. They are not durable across an app restart or session expiration. A duplicate successful request returns a completion notice, not its old screenshot. Never move an uncertain action to a new session or ID and assume it is safe to replay.
- Disconnects, sleep, manual takeover, preference changes, and token regeneration cancel pending automation. Work already delivered to the KVM may finish.
- Editing the device identity or supplying changed credentials revokes existing MCP access. Disable and re-enable MCP to issue new credentials. Regenerating the token also invalidates existing clients.

Recent activity records client-reported names, tool names, time and outcome only. It stays in memory and is bounded to 100 entries. The server retains each client's latest frame for coordinate validation and OCR, and hashes action arguments for duplicate detection; it does not put screenshot or typed-text content in the activity log.

## Protocol and bounds

The endpoint implements the JSON response mode of [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), negotiating 2025-11-25, 2025-06-18 or 2025-03-26. It supports initialization, initialized notifications, ping, tools/list, tools/call, cancellation notifications and session deletion. GET returns 405 because server-initiated SSE streaming is not offered. Screenshots are on-demand images from the live feed, not a continuous video stream.

Requests require the per-device bearer token, exact loopback Host, a valid loopback Origin if supplied, and JSON Content-Type. POST clients must accept both application/json and text/event-stream. Header size is limited to 16 KiB and body size to 1 MiB. There are at most 16 initialized clients, 32 HTTP connections, and one operation per client. HTTP request bodies use Content-Length; chunked uploads are rejected. Concurrent action attempts receive a busy/ownership error, not an implicit queue.

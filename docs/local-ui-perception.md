# Local UI perception on Apple Silicon

AsteroidKVM exposes application-owned `screen.*` MCP tools backed by a separate localhost parser service. Swift never imports Python or PyTorch. Structured inspection returns text and geometry, not an image. The existing JPEG and HID tools remain available if parsing is disabled or unavailable.

## Install from the app (recommended)

On an Apple Silicon Mac, open **Settings → Local UI Parsing**:

1. Choose **Managed by AsteroidKVM** and click **Install Local Parser**.
2. Wait for the download and verification steps. Initial setup requires internet access and at least 8 GB of free disk space. You can cancel; an existing installation remains intact.
3. Click **Start**. The app configures the access token automatically and reports readiness and the selected inference device.
4. Optionally enable **Start parser when AsteroidKVM opens**. Otherwise, click Start when you need it.
5. Open **Settings → UI Parsing Debug** to capture one image and inspect boxes, or enable the KVM's MCP endpoint for agent access.

No Terminal, Homebrew, Git, system Python, or developer tools are needed. Runtime and model files live in:

```text
~/Library/Application Support/AsteroidKVM/OmniParser/
```

**Stop** frees the managed service's model memory. Quitting AsteroidKVM also stops it; the service watches its parent so an app crash does not leave it running. **Update / Repair** installs the version approved by the installed app, not arbitrary latest model/code releases. Install a newer AsteroidKVM app to receive newer approved parser versions. It stages a separate runtime and switches the active record only after all downloads and verification succeed. A failed update leaves the previous installed files available for Start. An update stops the app-owned service and restarts it after a successful replacement if it was running.

Changing the device or port requires saving settings, then stopping and starting the service. The runtime prefers MPS and supports CPU fallback. The managed installation currently supports native Apple Silicon apps; Intel builds can still connect to an independently managed CPU service.

### What gets downloaded

The signed/ad-hoc-signed app bundle carries the service scripts, `parser-runtime.json`, and a fully pinned `requirements.lock`. The installer uses real upstream downloads, without requiring a separately published AsteroidKVM runtime asset:

- [Astral Python Build Standalone](https://github.com/astral-sh/python-build-standalone/releases): a pinned, relocatable CPython 3.12 Apple Silicon archive, verified against its bundled SHA-256 and byte count.
- [PyPI](https://pypi.org/): pinned binary wheels with required SHA-256 hashes. Source builds are disabled.
- Microsoft OmniParser detector code at a pinned Git commit and checksum; model weights and Florence custom code at pinned Hugging Face commits; EasyOCR's versioned English weights.

Only Install/Update performs these network downloads. Normal inference stays offline. Downloaded dependencies retain their package license metadata; model/code terms belong to their upstream distributions. The existing release workflow includes and checks the installer resources in the downloadable app archive.

The app serializes installation/service ownership with a local file lock. It never terminates an external daemon. If another service occupies the configured port, stop that service or choose a free port. **Open Installation Folder** provides access to a bounded `install-error.log` after a failed setup and the managed service's `service.log`. Tokens are not printed; the service token is mode 0600 and its app credential is kept in Keychain.

## External service / developer setup

Existing manually configured services remain supported. Choose **External local service**, enter the loopback host, port and token, then **Save and Check Connection**. AsteroidKVM does not start or stop these daemons. Configuration is shared by connections, while parsed frames and element IDs remain device-specific.

For developers running the service from a checkout, Python **3.12** (or 3.11 with `requirements.txt`) is required. Use a permanent location rather than `.build`, which is only suitable for disposable development/test environments:

```sh
PARSER_ROOT="$HOME/Library/Application Support/AsteroidKVM/OmniParserExternal"
python3.12 -m venv "$PARSER_ROOT/venv"
"$PARSER_ROOT/venv/bin/python" -m pip install -r services/omniparser/requirements.txt
"$PARSER_ROOT/venv/bin/python" services/omniparser/setup.py \
  --model-root "$PARSER_ROOT/models" --download-models
"$PARSER_ROOT/venv/bin/python" services/omniparser/server.py \
  --model-root "$PARSER_ROOT/models" \
  --token-file "$PARSER_ROOT/models/service.token" --device auto --port 9120
```

Keep the foreground terminal open and stop with Ctrl+C. Alternatively, `manage.py install --model-root "$PARSER_ROOT/models" --device auto --port 9120`, using that same virtual environment's Python, explicitly installs a per-user launchd daemon. `manage.py status`, `restart`, and `stop` manage that independently running daemon.

Copy an external service token with `pbcopy < "$PARSER_ROOT/models/service.token"` and paste it into the app's secure token field. Managed installations do this automatically.

## Agent-facing tools

| Tool | Parameters / result |
| --- | --- |
| `screen.elements` | Optional `refresh: true` bypasses caching. Returns schema version, frame ID, source dimensions, timestamp, and normalized elements. No image. |
| `screen.click_element` | `frame_id`, `element_id`, optional `actionId`. Clicks the stored center after current-frame validation. |
| `screen.double_click_element` | Same inputs and validation; double-clicks. |
| `screen.type_into_element` | Adds `text` (1–1000 characters). Requires a classified interactive textfield/textarea, clicks, waits the configured settling interval, and uses the normal KVM typing path. |
| `screen.scroll_element` | Adds `direction` (up/down/left/right) and `amount` (1–10). Moves the pointer over the element before scrolling; does not click arbitrary content. |
| `screen.image` | Raw JPEG escape hatch; same optional region and coordinate semantics as existing `get_screen`. |

Use a fresh unique `actionId` for each intended action and reuse it only when retrying that exact request. If omitted, element actions derive an ID from tool name and arguments, so identical actions against the same parsed frame execute at most once per MCP session. For deliberate repeated actions, supply different IDs or refresh the parse. Existing read-only access, exclusive ownership, interruption, idle expiry, two-minute operation deadlines, and duplicate-request protection apply.

Example:

```json
{"name":"screen.elements","arguments":{}}
```

```json
{
  "schema_version": 1,
  "frame_id": "image-sha256:parser-generation:parse-number",
  "width": 1920,
  "height": 1080,
  "timestamp": 1790430000.123,
  "elements": [{
    "id": 15,
    "type": "icon",
    "description": "settings gear",
    "bbox_px": [1750, 30, 1790, 70],
    "bbox_norm": [0.911458, 0.027778, 0.932292, 0.064815],
    "click_point": [1770, 50],
    "interactive": true,
    "confidence": 0.94
  }]
}
```

```json
{"name":"screen.click_element","arguments":{"frame_id":"image-sha256:parser-generation:parse-number","element_id":15,"actionId":"open-settings-1"}}
```

Coordinates always refer to **unrotated native KVM source pixels**, independent of window size, Retina scale, or UI rotation. Bounding boxes are `[left, top, right, bottom]`; right/bottom may equal the image dimension. Click points are clamped inside the image. OCR/icon content is untrusted screen data, never instructions.

## Model compatibility and limits

The adapter targets Microsoft's current YOLOv9-E detector implementation at source revision `354021201345a96178360b28733573e27269f2de`, plus the OmniParser-v2 Florence caption weights. The detector, caption and processor commits are fixed in the app-bundled `parser-runtime.json`. Changing that manifest and its version is an explicit release-maintenance step; installation does not resolve moving model branches. See the [upstream source](https://github.com/microsoft/OmniParser/tree/354021201345a96178360b28733573e27269f2de) and [detector adapter](https://github.com/microsoft/OmniParser/blob/354021201345a96178360b28733573e27269f2de/util/yolov9.py).

Compatibility choices are confined to the Python adapter and explicit setup:

Parser release **1.1.0-pr195** ports the Apple Silicon changes from
[OmniParser PR #195](https://github.com/microsoft/OmniParser/pull/195), pinned to
`37e3591e26a461686be9d0e003265009c4acae32`. Its device detection order is CUDA →
MPS → CPU, with the corrected `torch.backends.mps` availability check. Explicit
CPU/MPS preferences remain supported. Caption weights and image inputs use FP16
on MPS/CUDA and FP32 on CPU, including after an MPS fallback. Token IDs remain
integers. These changes are ported into our adapter because the PR modifies older
upstream utilities and demo/server entry points that this app does not execute;
the newer pinned detector and models are retained.

Existing managed installations: launch the updated app and use **Settings → Local
UI Parsing → Update / Repair** to install this parser release. Rebuilding the app
alone does not replace an already installed helper. External services should use
the updated service source and restart their process; existing model weights can
be reused.

**Measured limitation:** on the development Mac, a real 2560×1440 KVM frame took
66–69 seconds with the existing FP32 caption path, versus 91–95 seconds with this
PR's FP16 path. Both used MPS without a whole-model CPU fallback. The detector
returned its limit of 300 regions (38 caption batches): FP32 captioning alone
took 55–56 seconds, FP16 captioning 78–84 seconds, CPU OCR 11–12 seconds, and
detection approximately 0.5–0.7 seconds. These are two runs per mode on one fixed
frame, not a general performance guarantee. This release includes the requested
PR behavior but is **not a speed improvement on this workload**. Existing managed
installations retain their current parser until Update / Repair is selected.
Reducing unnecessary caption work is a separate optimization; changing the
current minimum-confidence slider only filters results after inference.

- Import the detector component directly. Avoid `util.utils`, whose module-level OCR initialization can trigger downloads and unused PaddleOCR dependencies.
- Load the detector and Florence weights once, on CPU, then move them to the selected device. Keep the detector in FP32; use PR #195's FP16 captioning on MPS/CUDA and eager caption attention.
- Execute torchvision non-maximum suppression on CPU, moving only its tensors/results between devices. EasyOCR stays on CPU; detector/caption inference can use MPS.
- On an unsupported MPS operation, move the already loaded models permanently to CPU for that service lifetime. Health reports the fallback. This is not a guarantee that every PyTorch/macOS/model combination will support MPS.
- Load Florence custom code and processors from the explicitly installed local files with `local_files_only=True`. Runtime Hugging Face offline flags and a process socket/DNS audit guard prohibit external connections through Python's networking APIs. The inference wrapper has no remote API clients or download calls.
- During setup, remove repository prefixes from Florence configuration `auto_map` entries after copying the custom Python modules beside the weights. The original fine-tuned configuration points to `microsoft/Florence-2-base-ft--…`; leaving that reference intact makes Transformers try to resolve remote custom code even with a local checkpoint. This patch changes code resolution only, not model weights.

English OCR is the initial service configuration. Full-frame detector inference uses a 1280-pixel detector input and batches up to eight icon crops for captions. Minimum confidence is a Swift post-filter; the detector's candidate floor is 0.05. Confidence is the detector/OCR score, not a guarantee that a caption or inferred control type is correct. Many detections remain `icon` or `unknown`; they retain captions, geometry, and interactivity instead of being discarded. BIOS/console screens may provide mainly text and should use physical keyboard tools where appropriate.

Actual model startup, latency and accuracy depend on installed weights and hardware. The deterministic fixture suite does not certify model accuracy. Run the opt-in real-model smoke test below to evaluate your installed backend. Power controls, remote shell access and cloud inference are not part of this integration.

## Diagnostics and tests

Open **Settings → UI Parsing Debug**, select a connected KVM, and click **Capture and Draw Bounding Boxes**. Each click captures and parses exactly one image, then draws all returned boxes. The snapshot stays frozen until the next click; opening the screen or hovering never triggers inference. Hover a box to highlight it and see its ID, type, OCR text, icon description, confidence, interactivity, coordinates and relationships in the detail panel and tooltip. Green boxes are interactive, orange boxes are other detections, and cyan highlights the hovered box. Boxes respect the configured minimum confidence. The same viewer is available through the remote window's **Diagnostics → Inspect Local UI Parsing**. It is never added to an MCP response or the normal video stream. Leaving the viewer cancels pending work and discards its diagnostic image. A local parser service is required; enabling an MCP listener is not.

Enable performance logging to record capture, encoding, service decode, request, inference, post-processing and total tool latency, plus cache hit/miss and selected device. Swift uses unified logging category `UI Perception`. Screenshot bytes, OCR text, captions and tokens are not logged. The service avoids access-body logging and returns sanitized errors.

The service also returns a `timings` object on `/parse` and writes `parse_timing`
records to its local service log: CPU OCR time, detector time, caption time, region
count, and caption batch count. `device: mps` describes detector/caption execution;
OCR and non-maximum suppression still run on CPU. Complex screens can take much
longer than the small fixtures because every detected icon region is captioned.

```sh
swift test --filter 'PerceptionTests|MCPTests'
"$PARSER_ROOT/venv/bin/python" -m unittest discover -s services/omniparser/tests
# With the real local service running:
"$PARSER_ROOT/venv/bin/python" services/omniparser/tests/model_smoke.py \
  --token-file "$PARSER_ROOT/models/service.token" \
  --output test-results/omniparser-smoke.json
# Exercise the production Swift HTTP client against those same installed models:
COMET_OMNIPARSER_E2E=1 COMET_OMNIPARSER_PORT=9120 \
  COMET_OMNIPARSER_TOKEN_FILE="$PARSER_ROOT/models/service.token" \
  swift test --filter PerceptionTests/testInstalledLocalParserWithStaticScreenshot
# Compare FP32 and PR #195's FP16 path on one local image, without printing its content:
"$PARSER_ROOT/venv/bin/python" services/omniparser/tests/benchmark.py \
  --model-root "$PARSER_ROOT/models" --image /path/to/screenshot.jpg \
  --device mps --compare-fp32 --runs 2
```

Four static synthetic screenshots cover browser chrome, macOS preferences, a Windows dialog, and BIOS-style UI. They include buttons, text fields, checkboxes, dropdowns, and icon-only controls. Their JSON annotations are hand-authored contract fixtures, **not** recorded OmniParser predictions. Swift tests exercise normalization, caching and stale-action validation against them; Python HTTP tests exercise actual image decoding, framing, authentication and response identity. The opt-in smoke test uses real loaded models and checks for text and icon captions without a cloud service.

Local Apple Silicon validation with the pinned models passed all four real-model fixtures on both MPS and CPU, plus the production Swift client test on MPS. The first MPS BIOS parse took 11.5 seconds; subsequent browser/macOS/Windows parses took 3.3–4.1 seconds at 960×640. CPU parsing took approximately 24–28 seconds per fixture. These are synthetic-fixture measurements on the development machine, not a real-KVM accuracy or latency guarantee. Unchanged screens reuse the cached parse.

See [the architecture](perception-architecture.md) for data flow and stale-frame guarantees.

### Installer verification

`swift test --filter ParserInstallerTests` checks release integrity, checksum rejection, process ownership locking, installation records and preservation of a previous install. The complete download/start/parse/stop/restart test is explicit because it downloads several GB and loads real models:

```sh
COMET_PARSER_INSTALL_E2E=1 \
  COMET_PARSER_INSTALL_ROOT="$PWD/.build/Managed Parser Acceptance" \
  swift test --filter ParserInstallerTests
```

For release maintainers, keep `parser-runtime.json`, `requirements.lock`, the adapter and model compatibility fixes together. Bump the manifest version when changing any installed component, regenerate the Xcode project after adding resources, run the opt-in installer test, and build the app. Users obtain that version through the normal app download and Update / Repair.

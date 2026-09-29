# Local UI perception on Apple Silicon

AsteroidKVM exposes application-owned `screen.*` MCP tools backed by a separate localhost parser service. Swift never imports Python or PyTorch. Structured inspection returns text and geometry, not an image. The existing JPEG and HID tools remain available if parsing is disabled or unavailable.

## Local service setup

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

Configure the host and port in **Settings → Local UI Parsing**. Copy the service token with `pbcopy < "$PARSER_ROOT/models/service.token"` and paste it into the app's secure token field.

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

- Import the detector component directly. Avoid `util.utils`, whose module-level OCR initialization can trigger downloads and unused PaddleOCR dependencies.
- Load the detector and Florence weights once, on CPU, then move them to the selected device. Use FP32 and eager caption attention rather than CUDA-specific/half-precision paths.
- Execute torchvision non-maximum suppression on CPU, moving only its tensors/results between devices. EasyOCR stays on CPU; detector/caption inference can use MPS.
- On an unsupported MPS operation, move the already loaded models permanently to CPU for that service lifetime. Health reports the fallback. This is not a guarantee that every PyTorch/macOS/model combination will support MPS.
- Load Florence custom code and processors from the explicitly installed local files with `local_files_only=True`. Runtime Hugging Face offline flags and a process socket/DNS audit guard prohibit external connections through Python's networking APIs. The inference wrapper has no remote API clients or download calls.
- During setup, remove repository prefixes from Florence configuration `auto_map` entries after copying the custom Python modules beside the weights. The original fine-tuned configuration points to `microsoft/Florence-2-base-ft--…`; leaving that reference intact makes Transformers try to resolve remote custom code even with a local checkpoint. This patch changes code resolution only, not model weights.

English OCR is the initial service configuration. Full-frame detector inference uses a 1280-pixel detector input and batches up to eight icon crops for captions. Minimum confidence is a Swift post-filter; the detector's candidate floor is 0.05. Confidence is the detector/OCR score, not a guarantee that a caption or inferred control type is correct. Many detections remain `icon` or `unknown`; they retain captions, geometry, and interactivity instead of being discarded. BIOS/console screens may provide mainly text and should use physical keyboard tools where appropriate.

Actual model startup, latency and accuracy depend on installed weights and hardware. The deterministic fixture suite does not certify model accuracy. Run the opt-in real-model smoke test below to evaluate your installed backend. Power controls, remote shell access and cloud inference are not part of this integration.

## Diagnostics and tests

Enable performance logging to record capture, encoding, service decode, request, inference, post-processing and total tool latency, plus cache hit/miss and selected device. Swift uses unified logging category `UI Perception`. Screenshot bytes, OCR text, captions and tokens are not logged. The service avoids access-body logging and returns sanitized errors.

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

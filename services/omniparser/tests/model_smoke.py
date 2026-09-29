"""Opt-in real-model acceptance over synthetic screens. Never contacts a cloud inference service."""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9120)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    token = args.token_file.read_text().strip()
    def request(method, path, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", args.port, timeout=110)
        connection.request(method, path, body=body, headers={"Authorization": "Bearer " + token, "Content-Type": "image/png"})
        response = connection.getresponse()
        data = json.loads(response.read())
        connection.close()
        return response.status, data
    deadline = time.monotonic() + 180
    while True:
        status, health = request("GET", "/health")
        if status != 200 or health.get("error"):
            raise RuntimeError(f"Service unavailable: {health.get('error')}")
        if health["models_loaded"]:
            break
        if time.monotonic() >= deadline:
            raise TimeoutError("Models did not load within three minutes")
        time.sleep(1)
    results = {"health": health, "screens": []}
    root = Path(__file__).resolve().parents[3] / "Tests/Fixtures/Perception"
    for path in sorted(root.glob("*.png")):
        image = path.read_bytes()
        status, result = request("POST", "/parse", image)
        if status != 200:
            raise RuntimeError(f"Inference failed on {path.name}: {result.get('error')}")
        assert result["frame_id"] == hashlib.sha256(image).hexdigest()
        assert (result["width"], result["height"]) == (960, 640)
        assert result["detections"], "No elements returned"
        assert any(item.get("text") for item in result["detections"]), "OCR returned no text"
        if path.stem != "bios_console":
            assert any(item.get("description") for item in result["detections"]), "No icon captions returned"
        record = {"fixture": path.name, "elements": len(result["detections"]), "inference_ms": result["inference_ms"], "device": result["device"]}
        print(json.dumps(record), flush=True)
        results["screens"].append(record)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Explicit, repeatable model installation. Only this setup command uses the network."""
import argparse
import json
from pathlib import Path
import secrets
import shutil
import hashlib
import urllib.request

from backend import UPSTREAM_REVISION


def localize_model_code(root):
    """Florence fine-tuned configs reference remote code even beside a local checkpoint."""
    for name in ("icon_caption", "florence_processor"):
        for path in (Path(root) / "weights" / name).glob("*.json"):
            config = json.loads(path.read_text())
            if not isinstance(config, dict) or "auto_map" not in config:
                continue
            def local(value):
                if isinstance(value, str):
                    return value.split("--")[-1]
                if isinstance(value, list):
                    return [local(item) for item in value]
                return value
            config["auto_map"] = {key: local(value) for key, value in config["auto_map"].items()}
            path.write_text(json.dumps(config, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-root", type=Path, required=True)
    parser.add_argument("--download-models", action="store_true", required=True)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("parser-runtime.json"))
    args = parser.parse_args()
    root = args.model_root.expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(args.manifest.read_text())
    if manifest["upstream_revision"] != UPSTREAM_REVISION:
        raise ValueError("Service source and install manifest disagree")
    def progress(message, fraction):
        print(json.dumps({"phase": message, "progress": fraction}), flush=True)
    progress("Downloading pinned detector code", 0.02)
    upstream = root / "upstream"
    (upstream / "util").mkdir(parents=True, exist_ok=True)
    # Only this detector module is imported at inference. Git and developer tools are not required.
    url = f"https://raw.githubusercontent.com/microsoft/OmniParser/{UPSTREAM_REVISION}/util/yolov9.py"
    with urllib.request.urlopen(url, timeout=60) as response:
        code = response.read(1024 * 1024)
    if hashlib.sha256(code).hexdigest() != manifest["detector_code_sha256"]:
        raise ValueError("Detector code checksum mismatch")
    (upstream / "util/yolov9.py").write_bytes(code)
    with urllib.request.urlopen(f"https://raw.githubusercontent.com/microsoft/OmniParser/{UPSTREAM_REVISION}/LICENSE", timeout=60) as response:
        (upstream / "LICENSE").write_bytes(response.read(1024 * 1024))
    from huggingface_hub import snapshot_download, hf_hub_download
    from tqdm.auto import tqdm
    class DownloadProgress(tqdm):
        def update(self, count=1):
            result = super().update(count)
            if self.total and (result or self.n == self.total):
                progress("Downloading model files", min(0.89, 0.1 + 0.75 * self.n / self.total))
            return result
    revisions = manifest["models"]
    weights = root / "weights"
    progress("Downloading detector weights", 0.1)
    snapshot_download("microsoft/OmniParser-v2.0", revision=revisions["detector"], local_dir=weights,
                      allow_patterns=["icon_detect_v3/model.pt"], tqdm_class=DownloadProgress)
    progress("Downloading icon caption model", 0.35)
    snapshot_download("microsoft/OmniParser-v2.0", revision=revisions["caption"], local_dir=weights,
                      allow_patterns=["icon_caption/*", "LICENSE*"], tqdm_class=DownloadProgress)
    processor = weights / "florence_processor"
    snapshot_download("microsoft/Florence-2-base", revision=revisions["processor"], local_dir=processor,
                      allow_patterns=["*.json", "*.py", "*.txt", "*.model", "LICENSE*"], tqdm_class=DownloadProgress)
    # Florence custom code must be present locally beside the fine-tuned caption configuration.
    for source in processor.glob("*.py"):
        shutil.copy2(source, weights / "icon_caption" / source.name)
    localize_model_code(root)
    progress("Downloading OCR models", 0.9)
    import easyocr
    easyocr.Reader(["en"], gpu=False, model_storage_directory=str(weights / "easyocr"), download_enabled=True, verbose=False)
    token = root / "service.token"
    if not token.exists():
        with token.open("x") as handle:
            token.chmod(0o600)
            handle.write(secrets.token_urlsafe(32))
    (root / "manifest.json").write_text(json.dumps({"upstream_revision": UPSTREAM_REVISION, "models": revisions}, indent=2))
    progress("Models installed", 1.0)


if __name__ == "__main__":
    main()

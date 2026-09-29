"""OmniParser adapter: pinned upstream YOLOv9 + local Florence captions + CPU EasyOCR.
No upstream util.utils import: that module creates/downloads OCR models during import.
"""
import importlib.util
import time
from pathlib import Path

UPSTREAM_REVISION = "354021201345a96178360b28733573e27269f2de"
MPS_PATCH_REVISION = "37e3591e26a461686be9d0e003265009c4acae32"
SERVICE_VERSION = "1.1.0-pr195"


def detect_device(torch, preferred="auto"):
    """Port of OmniParser PR #195, including its torch.backends compatibility fix."""
    if preferred not in ("auto", "mps", "cpu"):
        raise ValueError("Device must be auto, mps, or cpu")
    if preferred == "cpu":
        return "cpu"
    if preferred == "auto" and torch.cuda.is_available():
        return "cuda"
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def caption_dtype(torch, device):
    # PR #195 uses FP16 caption inputs on MPS as well as CUDA. Move model weights
    # with the same dtype, and restore FP32 when falling back to CPU.
    return torch.float16 if device in ("cuda", "mps") else torch.float32


class OmniParserBackend:
    def __init__(self, root, preferred_device="auto"):
        import torch
        import easyocr
        from transformers import AutoModelForCausalLM, AutoProcessor
        from torchvision.ops import batched_nms

        self.torch = torch
        self.root = Path(root).resolve()
        self.requested_device = preferred_device
        self.device = detect_device(torch, preferred_device)
        self.fallback = preferred_device == "mps" and self.device == "cpu"
        self.model = "OmniParser-YOLOv9-E+Florence-2"
        self.version = f"{SERVICE_VERSION}+{UPSTREAM_REVISION[:12]}"
        self.last_timings = {}
        module_path = self.root / "upstream/util/yolov9.py"
        weights = self.root / "weights/icon_detect_v3/model.pt"
        if not module_path.is_file() or not weights.is_file():
            raise RuntimeError("Run setup.py --download-models before starting the service")
        spec = importlib.util.spec_from_file_location("asteroid_yolov9", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # torchvision NMS is not consistently implemented on MPS; only NMS moves to CPU.
        module.batched_nms = lambda boxes, scores, classes, iou: batched_nms(
            boxes.cpu(), scores.cpu(), classes.cpu(), iou).to(boxes.device)
        self.detector = module.YOLOv9Detector(model_path=weights, device="cpu")
        self.processor = AutoProcessor.from_pretrained(
            str(self.root / "weights/florence_processor"), trust_remote_code=True, local_files_only=True)
        self.caption = AutoModelForCausalLM.from_pretrained(
            str(self.root / "weights/icon_caption"), trust_remote_code=True, local_files_only=True,
            torch_dtype=torch.float32, attn_implementation="eager").eval()
        self.ocr = easyocr.Reader(["en"], gpu=False, download_enabled=False,
                                  model_storage_directory=str(self.root / "weights/easyocr"), verbose=False)
        self._move(self.device)
        # Warm up once. Unsupported MPS model operators fall back before accepting screenshots.
        from PIL import Image
        self.parse(Image.new("RGB", (640, 480), "white"))

    def _move(self, device):
        try:
            self.detector.model.to(device)
            self.detector.device = self.torch.device(device)
            self.caption.to(device=device, dtype=caption_dtype(self.torch, device))
            self.device = device
        except (RuntimeError, NotImplementedError):
            if device == "cpu":
                raise
            self.detector.model.to("cpu")
            self.detector.device = self.torch.device("cpu")
            self.caption.to(device="cpu", dtype=self.torch.float32)
            self.device = "cpu"
            self.fallback = True

    def parse(self, image):
        try:
            return self._parse(image)
        except (RuntimeError, NotImplementedError):
            if self.device != "mps":
                raise
            # Permanent fallback for this service lifetime; weights are retained, not downloaded/reloaded.
            self._move("cpu")
            self.fallback = True
            return self._parse(image)

    def _parse(self, image):
        import numpy as np
        start = time.perf_counter()
        width, height = image.size
        detections = []
        with self.torch.inference_mode():
            for points, text, confidence in self.ocr.readtext(np.asarray(image), detail=1, paragraph=False):
                xs, ys = zip(*points)
                box = [max(0, min(xs) / width), max(0, min(ys) / height),
                       min(1, max(xs) / width), min(1, max(ys) / height)]
                if box[0] >= box[2] or box[1] >= box[3]:
                    continue
                detections.append(dict(type="text", bbox=box, text=str(text), description=None,
                    interactive=False, confidence=float(confidence), metadata={"source": "easyocr", "original_bbox": [list(map(float, p)) for p in points]}))
            ocr_finished = time.perf_counter()
            result = self.detector.predict(image, conf=0.05, imgsz=1280, iou=0.5, max_det=300)[0]
            boxes = result.boxes.xyxy.detach().cpu().tolist()
            scores = result.boxes.conf.detach().cpu().tolist()
            regions = []
            for box, score in zip(boxes, scores):
                x1, y1, x2, y2 = box
                if x2 - x1 < 2 or y2 - y1 < 2:
                    continue
                normalized = [x1 / width, y1 / height, x2 / width, y2 / height]
                contained = [d["text"] for d in detections if d["type"] == "text" and
                             x1 / width <= d["bbox"][0] and y1 / height <= d["bbox"][1] and
                             x2 / width >= d["bbox"][2] and y2 / height >= d["bbox"][3]]
                regions.append((box, normalized, score, " ".join(contained) or None))
            detection_finished = time.perf_counter()
            for offset in range(0, len(regions), 8):
                batch = regions[offset:offset + 8]
                crops = [image.crop(tuple(region[0])).resize((64, 64)) for region in batch]
                inputs = self.processor(images=crops, text=["<CAPTION>"] * len(crops), return_tensors="pt").to(self.device)
                # Keep token IDs integral; only image tensors use the caption model's dtype.
                inputs["pixel_values"] = inputs["pixel_values"].to(dtype=caption_dtype(self.torch, self.device))
                generated = self.caption.generate(input_ids=inputs["input_ids"], pixel_values=inputs["pixel_values"],
                                                  max_new_tokens=32, num_beams=1, do_sample=False, early_stopping=False)
                captions = self.processor.batch_decode(generated, skip_special_tokens=True)
                for (box, normalized, score, text), caption in zip(batch, captions):
                    detections.append(dict(type="icon", bbox=normalized, text=text, description=caption.strip(),
                        interactive=True, confidence=float(score), metadata={"source": "icon_detect_v3", "original_bbox_px": box}))
        finished = time.perf_counter()
        # Tensor-to-CPU conversion and caption decoding above synchronize GPU results.
        # Measurements contain counts and timings only, never screen text or captions.
        self.last_timings = {"ocr_ms": (ocr_finished - start) * 1000,
            "detection_ms": (detection_finished - ocr_finished) * 1000,
            "caption_ms": (finished - detection_finished) * 1000,
            "caption_regions": len(regions), "caption_batches": (len(regions) + 7) // 8}
        return detections, (finished - start) * 1000

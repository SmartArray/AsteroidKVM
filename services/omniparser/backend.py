"""OmniParser adapter: pinned upstream YOLOv9 + local Florence captions + CPU EasyOCR.
No upstream util.utils import: that module creates/downloads OCR models during import.
"""
import importlib.util
import time
from pathlib import Path

UPSTREAM_REVISION = "354021201345a96178360b28733573e27269f2de"
class OmniParserBackend:
    def __init__(self, root, preferred_device="auto"):
        import torch
        import easyocr
        from transformers import AutoModelForCausalLM, AutoProcessor
        from torchvision.ops import batched_nms

        self.torch = torch
        self.root = Path(root).resolve()
        self.requested_device = preferred_device
        self.device = "mps" if preferred_device != "cpu" and torch.backends.mps.is_available() else "cpu"
        self.fallback = preferred_device == "mps" and self.device == "cpu"
        self.model = "OmniParser-YOLOv9-E+Florence-2"
        self.version = UPSTREAM_REVISION
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
            self.caption.to(device)
            self.device = device
        except (RuntimeError, NotImplementedError):
            if device == "cpu":
                raise
            self.detector.model.to("cpu")
            self.detector.device = self.torch.device("cpu")
            self.caption.to("cpu")
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
            for offset in range(0, len(regions), 8):
                batch = regions[offset:offset + 8]
                crops = [image.crop(tuple(region[0])).resize((64, 64)) for region in batch]
                inputs = self.processor(images=crops, text=["<CAPTION>"] * len(crops), return_tensors="pt").to(self.device)
                # FP32 avoids CPU/MPS half-precision and input/model dtype mismatches.
                inputs["pixel_values"] = inputs["pixel_values"].to(dtype=self.torch.float32)
                generated = self.caption.generate(input_ids=inputs["input_ids"], pixel_values=inputs["pixel_values"],
                                                  max_new_tokens=32, num_beams=1, do_sample=False, early_stopping=False)
                captions = self.processor.batch_decode(generated, skip_special_tokens=True)
                for (box, normalized, score, text), caption in zip(batch, captions):
                    detections.append(dict(type="icon", bbox=normalized, text=text, description=caption.strip(),
                        interactive=True, confidence=float(score), metadata={"source": "icon_detect_v3", "original_bbox_px": box}))
        return detections, (time.perf_counter() - start) * 1000

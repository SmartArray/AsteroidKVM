"""Opt-in local image benchmark. Prints timings/counts only, never OCR or captions."""
import argparse
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server import enforce_offline


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model-root', type=Path, required=True)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--device', choices=('auto', 'mps', 'cpu'), default='auto')
    parser.add_argument('--compare-fp32', action='store_true')
    parser.add_argument('--runs', type=int, choices=range(1, 6), default=2)
    args = parser.parse_args()
    enforce_offline()
    import backend
    from PIL import Image
    start = time.perf_counter()
    model = backend.OmniParserBackend(args.model_root, args.device)
    print(json.dumps({'event': 'loaded', 'device': model.device, 'fallback': model.fallback,
        'version': model.version, 'startup_seconds': time.perf_counter() - start}), flush=True)
    with Image.open(args.image) as source:
        image = source.convert('RGB')
    patched_dtype = backend.caption_dtype
    modes = ['fp32_baseline', 'pr195'] if args.compare_fp32 else ['pr195']
    for mode in modes:
        backend.caption_dtype = (lambda torch, device: torch.float32) if mode == 'fp32_baseline' else patched_dtype
        model._move(model.device)
        for run in range(args.runs):
            detections, elapsed = model.parse(image)
            print(json.dumps({'event': 'parse', 'mode': mode, 'run': run + 1,
                'device': model.device, 'fallback': model.fallback,
                'caption_dtype': str(next(model.caption.parameters()).dtype),
                'width': image.width, 'height': image.height, 'elements': len(detections),
                'inference_ms': elapsed, **model.last_timings}), flush=True)
    backend.caption_dtype = patched_dtype


if __name__ == '__main__':
    main()

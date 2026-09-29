#!/usr/bin/env python3
"""Local-only image parsing service. No remote inference, model downloads, or image logging."""
import argparse
import hashlib
import hmac
import io
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 20 * 1024 * 1024
MAX_PIXELS = 33_554_432


def enforce_offline():
    for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_DATASETS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY"):
        os.environ[key] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
    def audit(event, args):
        if event == "socket.connect":
            address = args[1]
            if isinstance(address, tuple) and address[0] not in ("127.0.0.1", "::1"):
                raise PermissionError("External network access is disabled during inference")
        if event == "socket.getaddrinfo" and args[0] not in ("127.0.0.1", "::1", "localhost", None):
            raise PermissionError("External DNS is disabled during inference")
        if event in ("subprocess.Popen", "os.system"):
            raise PermissionError("Child processes are disabled during inference")
    sys.addaudithook(audit)


class ParserHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    # Reuse sockets in TIME_WAIT after Stop; an active listener still excludes duplicate services.
    allow_reuse_address = True
    def __init__(self, port, token, preferred="auto"):
        # Bind before loading models: starting a second service on this port fails before allocating weights.
        super().__init__(("127.0.0.1", port), Handler)
        self.token = token
        self.preferred = preferred
        self.backend = None
        self.load_error = None
        self.inference_lock = threading.Lock()
        self.connections = threading.BoundedSemaphore(16)

    def process_request(self, request, address):
        if not self.connections.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.connections.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.connections.release()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *args):
        pass  # No request bodies, OCR strings, tokens or model output in access logs.

    def send_json(self, status, payload):
        data = json.dumps(payload, allow_nan=False, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def authorized(self):
        expected_host = f"127.0.0.1:{self.server.server_port}"
        if self.headers.get("Host") != expected_host or self.headers.get("Origin") is not None:
            self.send_json(403, {"error": "FORBIDDEN"})
            return False
        values = self.headers.get_all("Authorization", [])
        if len(values) != 1 or not hmac.compare_digest(values[0], "Bearer " + self.server.token):
            self.send_json(401, {"error": "UNAUTHORIZED"})
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        if self.path != "/health":
            self.send_json(404, {"error": "NOT_FOUND"})
            return
        backend = self.server.backend
        self.send_json(200, {"schema_version": 1, "alive": True, "models_loaded": backend is not None,
            "device": backend.device if backend else "other", "preferred_device": self.server.preferred,
            "model": backend.model if backend else "OmniParser", "version": backend.version if backend else None,
            "cpu_fallback": backend.fallback if backend else False, "error": self.server.load_error})

    def do_POST(self):
        if not self.authorized():
            return
        if self.path != "/parse":
            self.send_json(404, {"error": "NOT_FOUND"})
            return
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or not lengths[0].isdigit():
            self.send_json(400, {"error": "INVALID_LENGTH"})
            return
        length = int(lengths[0])
        if not 0 < length <= MAX_BODY:
            self.send_json(413, {"error": "IMAGE_TOO_LARGE"})
            return
        if self.headers.get("Content-Type") not in ("image/jpeg", "image/png"):
            self.send_json(415, {"error": "UNSUPPORTED_IMAGE"})
            return
        if self.server.backend is None:
            self.send_json(503, {"error": "MODELS_UNAVAILABLE", "message": "Models are loading or setup is incomplete. Check /health."})
            return
        requested = self.headers.get("X-Preferred-Device", "auto")
        if requested not in ("auto", "cpu", "mps"):
            self.send_json(400, {"error": "INVALID_DEVICE"})
            return
        if requested != "auto" and requested != self.server.backend.device and not (requested == "mps" and self.server.backend.fallback):
            self.send_json(409, {"error": "DEVICE_MISMATCH", "message": "Restart the service with the requested device. Models are not reloaded per request."})
            return
        if not self.server.inference_lock.acquire(blocking=False):
            self.send_json(503, {"error": "PARSER_BUSY", "message": "Another parse is running. Retry after it finishes."})
            return
        try:
            started = time.perf_counter()
            body = self.rfile.read(length)
            if len(body) != length:
                self.send_json(400, {"error": "INCOMPLETE_IMAGE"})
                return
            from PIL import Image, UnidentifiedImageError
            Image.MAX_IMAGE_PIXELS = MAX_PIXELS
            try:
                with Image.open(io.BytesIO(body)) as source:
                    if source.format not in ("JPEG", "PNG") or source.width * source.height > MAX_PIXELS or max(source.size) > 8192:
                        raise ValueError("Invalid image size or format")
                    source.load()
                    image = source.convert("RGB")
            except (ValueError, UnidentifiedImageError, OSError, Image.DecompressionBombError):
                self.send_json(400, {"error": "INVALID_IMAGE"})
                return
            decode_ms = (time.perf_counter() - started) * 1000
            detections, inference_ms = self.server.backend.parse(image)
            timings = getattr(self.server.backend, "last_timings", {})
            print(json.dumps({"event": "parse_timing", "device": self.server.backend.device,
                "decode_ms": decode_ms, "inference_ms": inference_ms, **timings}), flush=True)
            self.send_json(200, {"schema_version": 1, "frame_id": hashlib.sha256(body).hexdigest(),
                "width": image.width, "height": image.height, "detections": detections,
                "device": self.server.backend.device, "model": self.server.backend.model,
                "decode_ms": decode_ms, "inference_ms": inference_ms, "timings": timings})
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass
        except Exception:
            self.send_json(500, {"error": "INFERENCE_FAILED", "message": "Local inference failed. Check model installation or restart with --device cpu."})
        finally:
            self.server.inference_lock.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-root", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--port", type=int, default=9120)
    parser.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
    parser.add_argument("--parent-pid", type=int, help="Exit if the managing app exits unexpectedly")
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("Port must be between 1024 and 65535")
    token = args.token_file.read_text().strip()
    if len(token) < 32:
        parser.error("Token file must contain at least 32 characters; run setup.py first")
    server = ParserHTTPServer(args.port, token, args.device)
    enforce_offline()
    def load():
        try:
            from backend import OmniParserBackend
            server.backend = OmniParserBackend(args.model_root, args.device)
            print(f"Models ready: {server.backend.device}", flush=True)
        except Exception as error:
            server.load_error = "MODEL_LOAD_FAILED"
            # Exception type only: upstream errors may contain image or OCR data.
            print(f"Model loading failed ({type(error).__name__}); verify setup or try --device cpu.", file=sys.stderr, flush=True)
    threading.Thread(target=load, daemon=True).start()
    def shutdown(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    if args.parent_pid is not None:
        def watch_parent():
            while True:
                if os.getppid() != args.parent_pid:
                    shutdown()
                    return
                time.sleep(1)
        threading.Thread(target=watch_parent, daemon=True).start()
    print(f"Local parser listening on 127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

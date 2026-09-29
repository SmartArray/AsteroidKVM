import hashlib
import http.client
import io
import json
from pathlib import Path
import subprocess
import socket
import sys
import threading
import tempfile
import unittest
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server import ParserHTTPServer
from backend import OmniParserBackend
from setup import localize_model_code

FIXTURES = Path(__file__).resolve().parents[3] / "Tests/Fixtures/Perception"
TOKEN = "test-local-parser-token-not-a-real-secret"


class FixtureBackend:
    device = "cpu"
    model = "fixture-contract-only"
    version = "1"
    fallback = False
    def parse(self, image):
        return [{"type": "icon", "bbox": [0.1, 0.2, 0.3, 0.4], "description": "settings gear",
                 "interactive": True, "confidence": 0.9}], 1.0


class BackendFallbackTests(unittest.TestCase):
    def test_managed_service_exits_when_its_parent_is_gone(self):
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory) / "token"
            token.write_text("test-token-" * 8)
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            code = """
import sys, types
class Backend:
    def __init__(self, *args): self.device = 'cpu'
sys.modules['backend'] = types.SimpleNamespace(OmniParserBackend=Backend)
from server import main
sys.argv = ['server.py', '--model-root', sys.argv[1], '--token-file', sys.argv[2], '--port', sys.argv[3], '--parent-pid', '0']
main()
"""
            result = subprocess.run([sys.executable, "-c", code, directory, str(token), str(port)],
                                    cwd=Path(__file__).resolve().parents[1], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_florence_custom_code_references_are_localized_during_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("icon_caption", "florence_processor"):
                path = root / "weights" / name / "config.json"
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps({"auto_map": {
                    "AutoConfig": "microsoft/Florence-2-base-ft--configuration_florence2.Florence2Config",
                    "AutoProcessor": ["microsoft/Florence-2-base--processing_florence2.Florence2Processor", None],
                }, "model_type": "florence2"}))
            localize_model_code(root)
            localize_model_code(root)  # Repeated explicit setup stays idempotent.
            for path in (root / "weights").glob("*/config.json"):
                config = json.loads(path.read_text())
                self.assertEqual(config["auto_map"]["AutoConfig"], "configuration_florence2.Florence2Config")
                self.assertEqual(config["auto_map"]["AutoProcessor"], ["processing_florence2.Florence2Processor", None])
                self.assertEqual(config["model_type"], "florence2")

    def test_mps_failure_moves_existing_models_once_and_stays_on_cpu(self):
        backend = OmniParserBackend.__new__(OmniParserBackend)
        backend.device = "mps"
        backend.fallback = False
        moves = []
        def move(device):
            moves.append(device)
            backend.device = device
        def parse(image):
            if backend.device == "mps":
                raise NotImplementedError("Unsupported MPS operator")
            return ["parsed"], 1
        backend._move = move
        backend._parse = parse
        self.assertEqual(backend.parse(None)[0], ["parsed"])
        self.assertEqual(backend.parse(None)[0], ["parsed"])
        self.assertEqual(moves, ["cpu"])
        self.assertTrue(backend.fallback)

    def test_cpu_failures_are_not_retried_forever(self):
        backend = OmniParserBackend.__new__(OmniParserBackend)
        backend.device = "cpu"
        def parse(image):
            raise RuntimeError("CPU model failure")
        backend._parse = parse
        with self.assertRaises(RuntimeError):
            backend.parse(None)


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.server = ParserHTTPServer(0, TOKEN)
        self.server.backend = FixtureBackend()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        values = {"Authorization": "Bearer " + TOKEN, "Content-Type": "image/png"}
        values.update(headers or {})
        connection.request(method, path, body=body, headers=values)
        response = connection.getresponse()
        status, data = response.status, json.loads(response.read())
        connection.close()
        return status, data

    def test_health_and_loading_state(self):
        code, result = self.request("GET", "/health")
        self.assertEqual(code, 200)
        self.assertTrue(result["models_loaded"])
        self.assertEqual(result["device"], "cpu")
        self.server.backend = None
        _, result = self.request("GET", "/health")
        self.assertTrue(result["alive"])
        self.assertFalse(result["models_loaded"])
        code, _ = self.request("POST", "/parse", b"png")
        self.assertEqual(code, 503)

    def test_active_port_is_exclusive_but_stopped_service_restarts_immediately(self):
        port = self.server.server_port
        with self.assertRaises(OSError):
            ParserHTTPServer(port, TOKEN)
        self.request("GET", "/health")
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.server = ParserHTTPServer(port, TOKEN)
        self.server.backend = FixtureBackend()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        code, result = self.request("GET", "/health")
        self.assertEqual(code, 200)
        self.assertTrue(result["models_loaded"])

    def test_static_screenshots_and_jpeg_have_exact_frame_ids(self):
        for path in FIXTURES.glob("*.png"):
            image = path.read_bytes()
            code, result = self.request("POST", "/parse", image)
            self.assertEqual(code, 200)
            self.assertEqual(result["frame_id"], hashlib.sha256(image).hexdigest())
            self.assertEqual((result["width"], result["height"]), (960, 640))
            self.assertEqual(result["detections"][0]["description"], "settings gear")
        data = io.BytesIO()
        Image.new("RGB", (100, 80)).save(data, format="JPEG")
        code, result = self.request("POST", "/parse", data.getvalue(), {"Content-Type": "image/jpeg"})
        self.assertEqual(code, 200)
        self.assertEqual(result["width"], 100)

    def test_invalid_auth_origin_body_and_device(self):
        code, _ = self.request("GET", "/health", headers={"Authorization": "Bearer wrong"})
        self.assertEqual(code, 401)
        code, _ = self.request("GET", "/health", headers={"Origin": "https://example.test"})
        self.assertEqual(code, 403)
        code, _ = self.request("POST", "/parse", b"not an image")
        self.assertEqual(code, 400)
        code, _ = self.request("POST", "/parse", b"{}", {"Content-Type": "application/json"})
        self.assertEqual(code, 415)
        code, _ = self.request("POST", "/parse", b"x", {"Content-Length": str(21*1024*1024)})
        self.assertEqual(code, 413)
        code, result = self.request("POST", "/parse", b"x", {"X-Preferred-Device": "mps"})
        self.assertEqual(code, 409)
        self.assertEqual(result["error"], "DEVICE_MISMATCH")

    def test_inference_serialization(self):
        self.server.inference_lock.acquire()
        try:
            code, result = self.request("POST", "/parse", b"x")
            self.assertEqual(code, 503)
            self.assertEqual(result["error"], "PARSER_BUSY")
        finally:
            self.server.inference_lock.release()

    def test_offline_policy_blocks_external_sockets_before_connection(self):
        code = "from server import enforce_offline; import socket; enforce_offline(); socket.create_connection(('example.com', 443))"
        result = subprocess.run([sys.executable, "-c", code], cwd=Path(__file__).resolve().parents[1], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"External DNS is disabled", result.stderr)


if __name__ == "__main__":
    unittest.main()

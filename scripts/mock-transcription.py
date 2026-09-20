#!/usr/bin/env python3
# Exercise the production WebSocket transport with synthetic audio and no OpenAI credentials or billing.
import base64
import hashlib
import json
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# A strict fixture rejects malformed configuration/audio before sending reordered transcription events.
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def frame(self, value):
        data = json.dumps(value).encode()
        header = bytes([0x81, len(data)]) if len(data) < 126 else bytes([0x81, 126]) + struct.pack("!H", len(data))
        self.wfile.write(header + data)
        self.wfile.flush()

    def read_frame(self):
        header = self.rfile.read(2)
        if len(header) != 2 or header[0] & 15 == 8:
            return None
        length = header[1] & 127
        if length == 126:
            length = struct.unpack("!H", self.rfile.read(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.rfile.read(8))[0]
        if length > 100000:
            raise ValueError("oversized test input")
        mask = self.rfile.read(4)
        data = self.rfile.read(length)
        return json.loads(bytes(c ^ mask[i % 4] for i, c in enumerate(data)))

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer fixture-key":
            self.send_error(401)
            return
        key = self.headers["Sec-WebSocket-Key"]
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        try:
            config = self.read_frame()
            audio = config["session"]["audio"]["input"]
            assert config["type"] == "session.update"
            assert config["session"]["type"] == "transcription"
            assert audio["format"] == {"type": "audio/pcm", "rate": 24000}
            assert audio["transcription"]["model"] == "gpt-live-transcribe"
            self.frame({"type": "session.updated"})
            sent = False
            while True:
                event = self.read_frame()
                if event is None:
                    return
                assert event["type"] == "input_audio_buffer.append"
                assert len(base64.b64decode(event["audio"], validate=True)) == 4800
                if not sent:
                    sent = True
                    self.frame({"type": "input_audio_buffer.committed", "item_id": "a", "previous_item_id": None})
                    self.frame({"type": "input_audio_buffer.committed", "item_id": "b", "previous_item_id": "a"})
                    self.frame({"type": "conversation.item.input_audio_transcription.delta", "item_id": "a", "delta": "Hello"})
                    self.frame({"type": "conversation.item.input_audio_transcription.completed", "item_id": "b", "transcript": "Second sentence."})
                    self.frame({"type": "conversation.item.input_audio_transcription.completed", "item_id": "a", "transcript": "Hello from remote audio."})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            self.frame({"type": "error"})


# Bind only loopback and let the OS choose an available port for concurrent test runs.
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
server.serve_forever()

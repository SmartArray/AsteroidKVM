#!/usr/bin/env python3
# A deterministic local protocol fixture records actual HTTP and WebSocket traffic for E2E assertions.
import base64
import hashlib
import itertools
import json
import struct
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Keep one appliance state per fixture process, including unknown fields used to verify merge preservation.
state = {
    "config": {"unowned": {"keep": 42}, "mouse_polling": 10},
    "events": [],
    "tokens": set(),
    "pastes": [],
    "params": {
        "desired_fps": 60,
        "h264_bitrate": 5000,
        "h264_gop": 60,
        "video_format": 0,
        "zero_delay": False,
        "venc_mode": "smart",
    },
}
lock = threading.Lock()
token_numbers = itertools.count(1)


# Exercise actual HTTP and WebSocket framing while avoiding dependencies outside the Python standard library.
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Suppress ordinary access logs so test output never contains request credentials or pasted text.
    def log_message(self, *_):
        pass

    # Match Comet's response envelope and explicit byte length for persistent HTTP connections.
    def reply(self, result, code=200):
        data = json.dumps({"ok": code == 200, "result": result}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # Accept the two authentication mechanisms supported by the production transport.
    def token(self):
        return self.headers.get("Token") or self.headers.get("Cookie", "").removeprefix(
            "auth_token="
        )

    # Route state reads through the same authentication boundary as mutations.
    def do_GET(self):
        self.route()

    # Record real mutation requests so assertions can detect duplicates and lost unknown fields.
    def do_POST(self):
        self.route()

    # Implement only the inspected API surface needed by the fixture; missing capabilities return 404.
    def route(self):
        path = urllib.parse.urlsplit(self.path).path
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if path == "/api/auth/login":
            fields = urllib.parse.parse_qs(body.decode())
            if fields.get("passwd") != ["test-password"]:
                return self.reply({}, 403)
            # Never reuse a token after logout, even when two sessions authenticate concurrently.
            with lock:
                token = "test-" + str(next(token_numbers))
                state["tokens"].add(token)
            return self.reply({"token": token})
        if path == "/test/state":
            return self.reply({k: v for k, v in state.items() if k != "tokens"})
        if self.token() not in state["tokens"]:
            return self.reply({}, 403)
        if path == "/test/offer":
            state["offer"] = json.loads(body)
            return self.reply({})
        if path == "/api/auth/check":
            return self.reply({})
        if path == "/api/auth/logout":
            state["tokens"].discard(self.token())
            return self.reply({})
        if path == "/api/hid/keymaps":
            return self.reply(
                {
                    "keymaps": {"default": "en-us", "available": ["en-us", "de"]},
                    "mapped_text": True,
                }
            )
        if path == "/api/hid":
            return self.reply(
                {
                    "keyboard": {"online": True},
                    "mouse": {"online": True},
                    "jiggler": {"enabled": False},
                }
            )
        if path == "/api/streamer":
            return self.reply(
                {
                    "params": state["params"],
                    "limits": {
                        "h264_bitrate": {"min": 0, "max": 20000},
                        "desired_fps": {"min": 1, "max": 60},
                        "h264_gop": {"min": 0, "max": 300},
                    },
                    "streamer": {
                        "source": {
                            "online": True,
                            "resolution": {"width": 1920, "height": 1080},
                        }
                    },
                }
            )
        if path == "/api/streamer/set_params":
            state["params"].update(
                {k: int(v[0]) if v[0].isdigit() else v[0] for k, v in query.items()}
            )
            return self.reply({})
        if path == "/api/system/get_config":
            return self.reply({"config": state["config"]})
        if path == "/api/system/set_config":
            state["config"] = json.loads(body)
            return self.reply({"config": state["config"]})
        if path == "/api/system/get_param":
            return self.reply({"absolute_mouse": True})
        if path == "/api/system/capability":
            return self.reply({"capability": {"cpu_model": "fixture"}})
        if path == "/api/system/otg_functions":
            return self.reply(
                {"enable_keyboard": True, "enable_mouse": True, "enable_mic": False}
            )
        if path == "/api/hid/print":
            state["pastes"].append(
                {
                    "text": body.decode(),
                    "keymap": query.get("keymap"),
                    "limit": query.get("limit"),
                    "token": self.token(),
                }
            )
            time.sleep(0.04)
            return self.reply({})
        if path in ["/api/ws", "/janus/ws"]:
            return self.websocket(janus=path == "/janus/ws")
        return self.reply({}, 404)

    # Implement WebSocket framing directly so the tests need no Python package installation.
    def websocket(self, janus=False):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(
            hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest()
        ).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        if janus:
            self.send_header("Sec-WebSocket-Protocol", "janus-protocol")
        self.end_headers()

        def send(value):
            data = json.dumps(value).encode()
            header = (
                bytes([129, len(data)])
                if len(data) < 126
                else bytes([129, 126]) + struct.pack("!H", len(data))
            )
            self.wfile.write(header + data)
            self.wfile.flush()

        if not janus:
            send({"event_type": "loop", "event": {"version": {"major": 4, "minor": 0}}})
        try:
            while True:
                head = self.rfile.read(2)
                if len(head) < 2 or head[0] & 15 == 8:
                    break
                size = head[1] & 127
                if size == 126:
                    size = struct.unpack("!H", self.rfile.read(2))[0]
                elif size == 127:
                    size = struct.unpack("!Q", self.rfile.read(8))[0]
                mask = self.rfile.read(4) if head[1] & 128 else None
                data = self.rfile.read(size)
                if mask:
                    data = bytes(v ^ mask[i % 4] for i, v in enumerate(data))
                event = json.loads(data)
                if janus:
                    self.janus_event(event, send)
                    continue
                state["events"].append({"token": self.token(), **event})
                if event["event_type"] == "mapped_text":
                    send(
                        {
                            "event_type": "mapped_text_result",
                            "event": {
                                "mapped": len(event["event"]["text"]) == 1,
                                "text": event["event"]["text"],
                            },
                        }
                    )
                elif event["event_type"] == "ping":
                    send({"event_type": "pong", "event": {}})
        except (OSError, ValueError):
            pass
        self.close_connection = True

    # Translate the Janus envelope while the Swift fixture provides a genuine native WebRTC sender.
    def janus_event(self, event, send):
        method = event["janus"]
        transaction = event.get("transaction", "")
        if method in ["create", "attach"]:
            send(
                {
                    "janus": "success",
                    "transaction": transaction,
                    "data": {"id": 100 if method == "create" else 200},
                }
            )
        elif method == "trickle":
            state.setdefault("candidates", []).append(event["candidate"])
        elif method == "message":
            request = event["body"]["request"]
            if request == "features":
                send(
                    {
                        "janus": "event",
                        "plugindata": {
                            "data": {
                                "result": {
                                    "status": "features",
                                    "features": {
                                        "audio": False,
                                        "mic": False,
                                        "ice": [],
                                    },
                                }
                            }
                        },
                    }
                )
            elif request == "watch":
                send(
                    {
                        "janus": "event",
                        "plugindata": {"data": {"result": {"status": "starting"}}},
                        "jsep": state["offer"],
                    }
                )
            elif request == "start":
                state["answer"] = event["jsep"]
                send({"janus": "webrtcup"})
        elif method == "keepalive":
            send({"janus": "ack", "transaction": transaction})


# Bind a random loopback port and print it once for the XCTest process that owns this fixture.
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()

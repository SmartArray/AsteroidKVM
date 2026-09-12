#!/usr/bin/env python3
# Exercise real TLS and redirects on loopback only, using disposable test certificates and synthetic credentials.
import json
import ssl
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# Echo only test requests so the suite can detect credential forwarding across origin boundaries.
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == '/redirect':
            target = urllib.parse.parse_qs(parsed.query)['target'][0]
            self.send_response(302)
            self.send_header('Location', target)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if parsed.path == '/echo':
            self.server.echoes += 1
        result = {
            'echoes': self.server.echoes,
            'cookie': self.headers.get('Cookie', ''),
            'token': self.headers.get('Token', ''),
        }
        body = json.dumps({'ok': True, 'result': result}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# An optional cert/key pair enables TLS without installing trust anchors or changing the host's Keychain.
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.echoes = 0
if len(sys.argv) == 3:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[1], sys.argv[2])
    server.socket = context.wrap_socket(server.socket, server_side=True)
print(server.server_port, flush=True)
server.serve_forever()

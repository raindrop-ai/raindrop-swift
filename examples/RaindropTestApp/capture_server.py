#!/usr/bin/env python3
"""Fake Raindrop ingest for the iOS app tests.

Records every request (path, headers, body, the status it was answered with) and answers
according to a switchable mode, so UI tests can make ingest fail and recover:

  ok    200 (events/track gets {"events":[]}, others {})
  down  503 with Retry-After: 30 (retryable; the SDK parks the batch)

Workshop mirror requests (/workshop/...) are always answered 200.

Control API (used by the UI tests):
  GET  /__health           {"ok": true}
  GET  /__requests         [{"path","status","headers","body"(base64)}...]
  POST /__mode             body {"mode": "ok" | "down"}
  POST /__reset            clears recorded requests, mode back to ok
"""
import argparse
import base64
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
STATE = {"mode": "ok", "requests": []}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, status, payload=b"", headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/__health":
            return self._send(200, b'{"ok":true}', {"Content-Type": "application/json"})
        if self.path == "/__requests":
            with LOCK:
                data = json.dumps(STATE["requests"]).encode()
            return self._send(200, data, {"Content-Type": "application/json"})
        self._send(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        if self.path == "/__mode":
            mode = json.loads(body or b"{}").get("mode", "ok")
            with LOCK:
                STATE["mode"] = mode
            return self._send(200, b"{}")
        if self.path == "/__reset":
            with LOCK:
                STATE["mode"] = "ok"
                STATE["requests"] = []
            return self._send(200, b"{}")

        with LOCK:
            mode = STATE["mode"]
        workshop = self.path.startswith("/workshop/")
        if mode == "down" and not workshop:
            status, payload, extra = 503, b'{"error":"down"}', {"Retry-After": "30"}
        else:
            status = 200
            payload = b'{"events":[]}' if self.path.endswith("/events/track") else b"{}"
            extra = {}
        with LOCK:
            STATE["requests"].append({
                "path": self.path,
                "status": status,
                "headers": {k: v for k, v in self.headers.items()},
                "body": base64.b64encode(body).decode(),
            })
        self._send(status, payload, {"Content-Type": "application/json", **extra})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8790)
    args = parser.parse_args()
    print(f"capture server on http://localhost:{args.port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()

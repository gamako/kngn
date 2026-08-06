#!/usr/bin/env python3
"""COOP/COEP static server for mic_demo e2e with a POST /__e2e_log sink.

Usage (from repo root, after package-web):
  python3 tests/e2e/serve_mic_e2e.py zig-out/web 8765 /tmp/mic-e2e-app.log

Chrome headless often does not surface console.log on stderr reliably; the page
posts [mic_demo] lines here when ?e2e=1 is on the URL.
"""

from __future__ import annotations

import http.server
import os
import sys
import threading
from pathlib import Path


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
    }
    log_path: Path = Path("/tmp/mic-e2e-app.log")
    _lock = threading.Lock()

    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        super().end_headers()

    def do_POST(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] != "/__e2e_log":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length > 0 else b""
        try:
            text = body.decode("utf-8", errors="replace").rstrip("\n")
        except Exception:
            text = repr(body)
        line = text + "\n"
        with self._lock:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(line)
        self.send_response(204)
        self.end_headers()

    def log_message(self, fmt: str, *args) -> None:
        # Keep server chatter on stderr for diagnosis.
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/web").resolve()
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
    log_path = Path(sys.argv[3] if len(sys.argv) > 3 else "/tmp/mic-e2e-app.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text("", encoding="utf-8")

    os.chdir(root)
    Handler.log_path = log_path
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"serving {root} on http://127.0.0.1:{port}/  (COOP/COEP, e2e log -> {log_path})", flush=True)
    print(f"  mic: http://127.0.0.1:{port}/mic-demo.html?e2e=1", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

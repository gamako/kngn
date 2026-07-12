#!/usr/bin/env python3
"""Local static server with COOP/COEP for synth wasm (SharedArrayBuffer).

Usage (from repo root, after `zig build package-web`):
  python3 zig-out/web/serve-coop-coep.py
  python3 zig-out/web/serve-coop-coep.py 8080

Pixie smoke without COOP/COEP:
  cd zig-out/web && python3 -m http.server 8080
"""

from __future__ import annotations

import http.server
import os
import sys


class CoopCoepHandler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
    }

    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        super().end_headers()

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main() -> None:
    # Script lives in zig-out/web/ after package-web install.
    root = os.path.dirname(os.path.abspath(__file__))
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    os.chdir(root)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), CoopCoepHandler)
    print(f"serving {root} on http://127.0.0.1:{port}/  (COOP/COEP)", flush=True)
    print("  pixie: http://127.0.0.1:%d/index.html" % port, flush=True)
    print("  synth: http://127.0.0.1:%d/synth.html" % port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye", flush=True)


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
"""Static file server with COOP/COEP for SharedArrayBuffer.

Usage:
  python3 scripts/serve-web.py [dir] [port]
  # default: zig-out/web on 8080

Headers:
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp
"""

from __future__ import annotations

import http.server
import os
import sys


class CoopCoepHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # Worklet / module scripts
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        super().end_headers()

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main() -> None:
    root = sys.argv[1] if len(sys.argv) > 1 else "zig-out/web"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
    os.chdir(root)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), CoopCoepHandler)
    print(f"serving {os.getcwd()} on http://127.0.0.1:{port}/  (COOP/COEP)", flush=True)
    print("  pixie: http://127.0.0.1:%d/index.html" % port, flush=True)
    print("  synth: http://127.0.0.1:%d/synth.html" % port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye", flush=True)


if __name__ == "__main__":
    main()

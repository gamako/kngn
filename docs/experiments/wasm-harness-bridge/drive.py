#!/usr/bin/env python3
"""Run harness commands against a kngn wasm application in a headless browser.

It serves the packaged web bundle together with `bridge.html`, launches one browser, and
then relays command batches to the page and their responses back, over plain HTTP. No
devtools connection is involved, so it works in an unattended shell.

Usage (after `zig build package-web -Dwasm-harness=true`, from the repository root):

    python3 docs/experiments/wasm-harness-bridge/drive.py --script /tmp/window.txt
    python3 docs/experiments/wasm-harness-bridge/drive.py -c 'step 5' -c 'digest window'

Each `--script` file and each `-c` is one *batch*: the whole text is handed to the harness
in one request, exactly as the TCP transport receives one connection's worth of commands,
and its response is printed. A batch beginning with `@` is a page command instead — see
`README.md`.

Read `--help` for the knobs.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import urlencode, urlparse

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
WEB_DIR = REPO_ROOT / "zig-out" / "web"

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    shutil.which("google-chrome") or "",
    shutil.which("chromium") or "",
    shutil.which("chromium-browser") or "",
]

# How long a pull is held open before answering "idle". Long enough that an idle driver is
# not a request storm, short enough that shutdown is prompt.
PULL_HOLD_S = 5.0


def find_chrome() -> str:
    for c in CHROME_CANDIDATES:
        if c and os.path.exists(c):
            return c
    sys.exit("no Chrome/Chromium binary found; pass --chrome")


class Session:
    """The command queue and the result rendezvous for one browser run."""

    def __init__(self, token: str) -> None:
        self.token = token
        self.pending: queue.Queue = queue.Queue()
        self.results: dict[int, dict] = {}
        self.results_cv = threading.Condition()
        self.ready = threading.Event()
        self.ready_info: dict = {}
        self.done = threading.Event()
        self.seq = 0

    def submit(self, cmd: str) -> int:
        self.seq += 1
        self.pending.put((self.seq, cmd))
        return self.seq

    def wait_result(self, seq: int, timeout_s: float) -> dict | None:
        deadline = time.time() + timeout_s
        with self.results_cv:
            while seq not in self.results:
                left = deadline - time.time()
                if left <= 0:
                    return None
                self.results_cv.wait(timeout=min(left, 0.5))
            return self.results.pop(seq)

    def put_result(self, seq: int, payload: dict) -> None:
        with self.results_cv:
            self.results[seq] = payload
            self.results_cv.notify_all()


class Handler(http.server.SimpleHTTPRequestHandler):
    """Static file server plus the three bridge endpoints."""

    session: Session | None = None
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
    }

    def _json(self, obj) -> None:
        raw = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self) -> None:  # noqa: N802 (http.server API)
        path = urlparse(self.path).path
        n = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            self.send_error(400)
            return
        s = Handler.session
        if s is None or body.get("token") != s.token:
            self.send_error(403)
            return

        if path == "/harness/ready":
            s.ready_info = body
            s.ready.set()
            self._json({})
        elif path == "/harness/pull":
            if s.done.is_set():
                self._json({"done": True})
                return
            try:
                seq, cmd = s.pending.get(timeout=PULL_HOLD_S)
            except queue.Empty:
                self._json({"idle": True})
                return
            self._json({"seq": seq, "cmd": cmd})
        elif path == "/harness/result":
            s.put_result(int(body.get("seq", 0)), body)
            self._json({})
        else:
            self.send_error(404)

    def end_headers(self) -> None:
        # The clock resolution and the shared-memory audio transport both need isolation.
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt: str, *args) -> None:
        pass


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def launch_chrome(chrome: str, url: str, profile: str, win_w: int, win_h: int,
                  scale: str, console_log: Path | None) -> subprocess.Popen:
    argv = [
        chrome,
        "--headless=new",
        f"--user-data-dir={profile}",
        f"--window-size={win_w},{win_h}",
        f"--force-device-scale-factor={scale}",
        "--hide-scrollbars",
        # Without these, rAF stops in a backgrounded headless window and the page never
        # reaches a frame boundary, so no harness response is ever produced.
        "--disable-background-timer-throttling",
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
        # An AudioContext otherwise waits for a gesture that an unattended run cannot make.
        "--autoplay-policy=no-user-gesture-required",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=CalculateNativeWinOcclusion",
    ]
    if console_log is not None:
        argv += ["--enable-logging=stderr", "--v=0"]
    argv.append(url)
    out = console_log.open("wb") if console_log is not None else subprocess.DEVNULL
    return subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=out)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--script", action="append", default=[],
                    help="file whose whole text is one command batch (repeatable)")
    ap.add_argument("-c", "--cmd", action="append", default=[],
                    help="one command batch given inline (repeatable)")
    ap.add_argument("--wasm", default="pixie.wasm", help="module to boot")
    ap.add_argument("--audio-transport", default="none",
                    choices=["none", "worklet_shared", "worklet_postmessage"])
    ap.add_argument("--web-dir", default=str(WEB_DIR), help="packaged bundle (zig-out/web)")
    ap.add_argument("--chrome", default=None, help="browser binary")
    ap.add_argument("--size", default="780x600", help="canvas CSS size, WxH")
    ap.add_argument("--device-scale-factor", default="1",
                    help="the browser's devicePixelRatio for the run (launch-time only)")
    ap.add_argument("--capture-frames", action="store_true",
                    help="let the harness copy every framebuffer, which digest fb needs "
                         "and which costs a frame-sized memcpy per frame")
    ap.add_argument("--boot-timeout", type=float, default=60.0)
    ap.add_argument("--timeout", type=float, default=120.0, help="seconds to wait for one batch")
    ap.add_argument("--console-log", default=None,
                    help="write the browser's stderr (which carries the app's own output) here")
    ap.add_argument("--json", action="store_true", help="print one JSON object per batch")
    args = ap.parse_args()

    batches: list[str] = []
    for c in args.cmd:
        batches.append(c)
    for f in args.script:
        batches.append(Path(f).read_text())
    if not batches:
        sys.exit("nothing to run: pass --script or -c")

    web_dir = Path(args.web_dir).resolve()
    if not (web_dir / args.wasm).exists():
        sys.exit(f"no {args.wasm} under {web_dir}; "
                 f"run `zig build package-web -Dwasm-harness=true` first")

    # Serve the bundle and bridge.html from one directory, so the page is same-origin with
    # the module and the wasm.
    staging = Path(tempfile.mkdtemp(prefix="kngn-bridge-web-"))
    for item in web_dir.iterdir():
        if item.is_file():
            shutil.copy2(item, staging / item.name)
    shutil.copy2(HERE / "bridge.html", staging / "bridge.html")

    token = os.urandom(8).hex()
    session = Session(token)
    Handler.session = session

    port = free_port()
    httpd = http.server.ThreadingHTTPServer(
        ("127.0.0.1", port),
        lambda *a, **kw: Handler(*a, directory=str(staging), **kw),
    )
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    w, h = (int(v) for v in args.size.split("x"))
    q = urlencode({
        "token": token,
        "wasm": args.wasm,
        "audio-transport": args.audio_transport,
        "w": w,
        "h": h,
        "fb": "1" if args.capture_frames else "0",
    })
    url = f"http://127.0.0.1:{port}/bridge.html?{q}"

    chrome = args.chrome or find_chrome()
    console_log = Path(args.console_log) if args.console_log else None
    failures = 0
    with tempfile.TemporaryDirectory(prefix="kngn-bridge-") as profile:
        proc = launch_chrome(chrome, url, profile, w + 60, h + 160,
                             args.device_scale_factor, console_log)
        try:
            if not session.ready.wait(timeout=args.boot_timeout):
                print("boot: the page never reported ready", file=sys.stderr)
                failures += 1
            elif session.ready_info.get("error"):
                print("boot failed: " + session.ready_info["error"], file=sys.stderr)
                failures += 1
            else:
                if not args.json:
                    print(f"# ready device_pixel_ratio={session.ready_info.get('device_pixel_ratio')}")
                for batch in batches:
                    seq = session.submit(batch)
                    res = session.wait_result(seq, args.timeout)
                    if res is None:
                        print(f"# batch {seq}: timed out after {args.timeout}s", file=sys.stderr)
                        failures += 1
                        break
                    if res.get("error"):
                        failures += 1
                    if args.json:
                        print(json.dumps({"seq": seq, "cmd": batch,
                                          "response": res.get("response", ""),
                                          "error": res.get("error")}))
                    else:
                        print(f"# batch {seq}: {batch.strip()}")
                        if res.get("error"):
                            print("error: " + res["error"], file=sys.stderr)
                        sys.stdout.write(res.get("response", ""))
                    sys.stdout.flush()
        finally:
            session.done.set()
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
            httpd.shutdown()
            shutil.rmtree(staging, ignore_errors=True)

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()

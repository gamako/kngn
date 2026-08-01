#!/usr/bin/env python3
"""Drive the wasm frame-breakdown measurement in a headless browser.

It serves the packaged web bundle together with `bench.html`, launches one browser
per condition, and collects each run's JSON report over HTTP. No devtools connection
is involved, so it works in an unattended shell.

Usage (after `zig build package-web`, from the repository root):

    python3 docs/experiments/wasm-frame-breakdown/run.py --out /tmp/breakdown.json

Read `--help` for the knobs. `README.md` explains what the numbers mean and which
comparisons between conditions are legitimate.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import random
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


def find_chrome() -> str:
    for c in CHROME_CANDIDATES:
        if c and os.path.exists(c):
            return c
    sys.exit("no Chrome/Chromium binary found; pass --chrome")


class Collector(http.server.SimpleHTTPRequestHandler):
    """Static file server plus a POST /report sink."""

    reports: list = []
    lock = threading.Lock()
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
    }

    def do_POST(self) -> None:  # noqa: N802 (http.server API)
        if urlparse(self.path).path != "/report":
            self.send_error(404)
            return
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n)
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"error": "unparsable report", "raw": raw.decode("utf-8", "replace")}
        with Collector.lock:
            Collector.reports.append(payload)
        self.send_response(204)
        self.end_headers()

    def end_headers(self) -> None:
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


def serve(root: Path) -> tuple[http.server.ThreadingHTTPServer, int]:
    port = free_port()
    handler = type("Handler", (Collector,), {})
    httpd = http.server.ThreadingHTTPServer(
        ("127.0.0.1", port),
        lambda *a, **kw: handler(*a, directory=str(root), **kw),
    )
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, port


def run_one(chrome: str, port: int, cond: dict, timeout_s: float) -> bool:
    """Launch one browser for one condition and wait for *its* report to land.

    Reports are matched by the token this call generated, never by arrival order: a
    late report from a previous condition would otherwise be accepted as this one's.
    """
    token = cond["token"]
    q = urlencode(cond)
    url = f"http://127.0.0.1:{port}/bench.html?{q}"
    # The window must be at least the canvas, or the element's client box is clipped and
    # the app measures a smaller framebuffer than the condition asks for.
    win_w = int(cond["w"]) + 40
    win_h = int(cond["h"]) + 120
    with tempfile.TemporaryDirectory(prefix="kngn-bench-") as profile:
        proc = subprocess.Popen(
            [
                chrome,
                "--headless=new",
                f"--user-data-dir={profile}",
                f"--window-size={win_w},{win_h}",
                "--force-device-scale-factor=1",
                "--hide-scrollbars",
                # Without these, rAF stops in a backgrounded headless window and no
                # report is ever produced.
                "--disable-background-timer-throttling",
                "--disable-backgrounding-occluded-windows",
                "--disable-renderer-backgrounding",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-features=CalculateNativeWinOcclusion",
                url,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + timeout_s
        got = False
        try:
            while time.time() < deadline:
                with Collector.lock:
                    got = any(r.get("token") == token for r in Collector.reports)
                if got:
                    break
                if proc.poll() is not None:
                    # The browser exited; give a report already in flight a moment to land.
                    time.sleep(1.0)
                    with Collector.lock:
                        got = any(r.get("token") == token for r in Collector.reports)
                    break
                time.sleep(0.25)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
    return got


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="breakdown.json", help="where to write the collected reports")
    ap.add_argument("--chrome", default=None, help="browser binary")
    ap.add_argument("--web-dir", default=str(WEB_DIR), help="packaged bundle (zig-out/web)")
    ap.add_argument("--repeats", type=int, default=5, help="runs per condition")
    ap.add_argument("--frames", type=int, default=400, help="measured frames per run")
    ap.add_argument("--warmup", type=int, default=60, help="frames discarded before measuring")
    ap.add_argument("--timeout", type=float, default=90.0, help="seconds to wait for one report")
    ap.add_argument("--seed", type=int, default=1, help="seed for the run order shuffle")
    ap.add_argument("--sizes", default="64x64,780x600,1600x900,2560x1440")
    ap.add_argument("--present", default="real,split,stale,touch,none")
    ap.add_argument("--swizzle", default="real,memcpy,noop")
    ap.add_argument("--alias", default="on",
                    help="host present: on (alias wasm memory) / off (force the copy path)")
    ap.add_argument("--matrix", default="default", choices=["default", "full"],
                    help="'default' varies one axis at a time from the baseline; "
                         "'full' takes the cartesian product")
    args = ap.parse_args()

    web_dir = Path(args.web_dir).resolve()
    if not (web_dir / "pixie.wasm").exists():
        sys.exit(f"no pixie.wasm under {web_dir}; run `zig build package-web` first")

    # Serve the bundle and bench.html from one directory so the page is same-origin
    # with the module and the wasm.
    staging = Path(tempfile.mkdtemp(prefix="kngn-bench-web-"))
    for item in web_dir.iterdir():
        if item.is_file():
            shutil.copy2(item, staging / item.name)
    shutil.copy2(HERE / "bench.html", staging / "bench.html")
    wasm_bytes = (staging / "pixie.wasm").read_bytes()

    sizes = [tuple(int(v) for v in s.split("x")) for s in args.sizes.split(",")]
    presents = args.present.split(",")
    swizzles = args.swizzle.split(",")
    aliases = args.alias.split(",")

    conds = []
    if args.matrix == "full":
        for (w, h) in sizes:
            for p in presents:
                for s in swizzles:
                    for al in aliases:
                        conds.append({"w": w, "h": h, "present": p, "swizzle": s, "alias": al})
    else:
        # One axis at a time. Comparing two conditions that differ in two places tells
        # you nothing about either.
        for (w, h) in sizes:
            conds.append({"w": w, "h": h, "present": presents[0], "swizzle": swizzles[0],
                          "alias": aliases[0]})
        base_w, base_h = sizes[-1]
        for p in presents[1:]:
            conds.append({"w": base_w, "h": base_h, "present": p, "swizzle": swizzles[0],
                          "alias": aliases[0]})
        for s in swizzles[1:]:
            conds.append({"w": base_w, "h": base_h, "present": presents[0], "swizzle": s,
                          "alias": aliases[0]})
        for al in aliases[1:]:
            conds.append({"w": base_w, "h": base_h, "present": presents[0],
                          "swizzle": swizzles[0], "alias": al})

    plan = []
    for rep in range(args.repeats):
        for c in conds:
            plan.append({**c, "frames": args.frames, "warmup": args.warmup,
                         "token": f"r{rep}-{c['w']}x{c['h']}-{c['present']}-{c['swizzle']}-{c['alias']}",
                         "label": f"{c['w']}x{c['h']}/{c['present']}/{c['swizzle']}/"
                                  f"alias-{c['alias']}/rep{rep}"})
    # Randomised order: a fixed cycle leaves an order effect indistinguishable from a
    # condition effect.
    random.Random(args.seed).shuffle(plan)

    chrome = args.chrome or find_chrome()
    httpd, port = serve(staging)
    print(f"serving {staging} on 127.0.0.1:{port}", flush=True)
    print(f"{len(plan)} runs ({len(conds)} conditions x {args.repeats})", flush=True)

    t_start = time.time()
    for i, cond in enumerate(plan, 1):
        label = cond["label"]
        print(f"[{i}/{len(plan)}] {label}", flush=True)
        if not run_one(chrome, port, cond, args.timeout):
            Collector.reports.append({"label": label, "token": cond["token"],
                                      "error": "no report (timeout)", "conditions": cond})
            print("    no report", flush=True)
    httpd.shutdown()

    import hashlib
    wasm_sha = hashlib.sha256(wasm_bytes).hexdigest()
    # The measured system is the module plus the host glue plus this page. A change to the
    # glue moves the numbers while leaving the module identical, so the host side is
    # identified too — otherwise two such runs pool under one condition unnoticed.
    def sha_of(path: Path) -> str:
        try:
            return hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError:
            return ""
    host_sha = hashlib.sha256(
        (sha_of(Path(args.web_dir) / "kngn.js") + sha_of(HERE / "bench.html")).encode()
    ).hexdigest()
    for r in Collector.reports:
        r["wasm_sha256"] = wasm_sha
        r["host_sha256"] = host_sha
    out = {
        "meta": {
            "wasm_sha256": wasm_sha,
            "host_sha256": host_sha,
            "wasm_bytes": len(wasm_bytes),
            "chrome": chrome,
            "repeats": args.repeats,
            "frames": args.frames,
            "warmup": args.warmup,
            "seed": args.seed,
            "matrix": args.matrix,
            "elapsed_s": round(time.time() - t_start, 1),
        },
        "runs": Collector.reports,
    }
    Path(args.out).write_text(json.dumps(out, indent=2))
    print(f"wrote {args.out} ({len(Collector.reports)} reports)", flush=True)
    shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    main()

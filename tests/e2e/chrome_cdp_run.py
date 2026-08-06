#!/usr/bin/env python3
"""Drive headless Chrome via CDP: navigate, wait, collect console messages.

Usage:
  python3 tests/e2e/chrome_cdp_run.py \\
    --chrome "/path/to/Google Chrome" \\
    --url "http://127.0.0.1:8765/mic-demo.html?e2e=1" \\
    --wav /path/to/fake.wav \\
    --user-data-dir /tmp/chrome-profile \\
    --seconds 15 \\
    --console-log /tmp/mic-console.log
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import select
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any
from urllib.parse import urlparse


def http_json(url: str, timeout: float = 2.0) -> Any:
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def wait_json(url: str, timeout: float = 25.0) -> Any:
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        try:
            return http_json(url)
        except Exception as e:  # noqa: BLE001
            last = str(e)
            time.sleep(0.1)
    raise RuntimeError(f"timeout waiting for {url}: {last}")


class CdpWs:
    def __init__(self, ws_url: str) -> None:
        u = urlparse(ws_url)
        host = u.hostname or "127.0.0.1"
        port = u.port or 80
        path = u.path + (("?" + u.query) if u.query else "")
        self.sock = socket.create_connection((host, port), timeout=15)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode("ascii"))
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("ws handshake closed")
            buf += chunk
        if b"101" not in buf.split(b"\r\n", 1)[0]:
            raise RuntimeError("ws handshake failed")
        self._id = 0
        self._rx = b""

    def close(self) -> None:
        try:
            self.sock.close()
        except Exception:
            pass

    def send(self, obj: dict[str, Any]) -> None:
        data = json.dumps(obj).encode("utf-8")
        mask = os.urandom(4)
        header = bytearray([0x81])
        n = len(data)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += n.to_bytes(2, "big")
        else:
            header.append(0x80 | 127)
            header += n.to_bytes(8, "big")
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(header + masked)

    def recv_messages(self, timeout: float) -> list[dict[str, Any]]:
        self.sock.settimeout(timeout)
        out: list[dict[str, Any]] = []
        try:
            while True:
                try:
                    chunk = self.sock.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                self._rx += chunk
                while True:
                    msg, self._rx = self._pop(self._rx)
                    if msg is None:
                        break
                    out.append(json.loads(msg))
                r, _, _ = select.select([self.sock], [], [], 0)
                if not r:
                    break
        except socket.timeout:
            pass
        return out

    @staticmethod
    def _pop(buf: bytes) -> tuple[str | None, bytes]:
        if len(buf) < 2:
            return None, buf
        b0, b1 = buf[0], buf[1]
        opcode = b0 & 0x0F
        masked = (b1 & 0x80) != 0
        n = b1 & 0x7F
        i = 2
        if n == 126:
            if len(buf) < 4:
                return None, buf
            n = int.from_bytes(buf[2:4], "big")
            i = 4
        elif n == 127:
            if len(buf) < 10:
                return None, buf
            n = int.from_bytes(buf[2:10], "big")
            i = 10
        if masked:
            if len(buf) < i + 4 + n:
                return None, buf
            mask = buf[i : i + 4]
            i += 4
            payload = bytes(buf[i + j] ^ mask[j % 4] for j in range(n))
            i += n
        else:
            if len(buf) < i + n:
                return None, buf
            payload = buf[i : i + n]
            i += n
        rest = buf[i:]
        if opcode == 0x8:
            return None, b""
        if opcode != 0x1:
            return None, rest
        return payload.decode("utf-8"), rest

    def call(self, method: str, params: dict[str, Any] | None = None, timeout: float = 20.0) -> Any:
        self._id += 1
        mid = self._id
        msg: dict[str, Any] = {"id": mid, "method": method}
        if params:
            msg["params"] = params
        self.send(msg)
        deadline = time.time() + timeout
        extras: list[dict[str, Any]] = []
        while time.time() < deadline:
            for ev in self.recv_messages(min(1.0, max(0.05, deadline - time.time()))):
                if ev.get("id") == mid:
                    # push extras back... discard for simplicity; events after still drain
                    if "error" in ev:
                        raise RuntimeError(f"{method}: {ev['error']}")
                    return ev.get("result")
                if "method" in ev:
                    extras.append(ev)
            # keep looping until reply
        raise TimeoutError(method)


def append_log(path: str, line: str) -> None:
    with open(path, "a", encoding="utf-8") as f:
        f.write(line.rstrip("\n") + "\n")


def handle_event(ev: dict[str, Any], console_log: str) -> None:
    method = ev.get("method")
    params = ev.get("params") or {}
    line = None
    if method == "Runtime.consoleAPICalled":
        parts = []
        for a in params.get("args") or []:
            if "value" in a:
                parts.append(str(a["value"]))
            elif "description" in a:
                parts.append(str(a["description"]))
        line = " ".join(parts)
    elif method == "Log.entryAdded":
        line = str((params.get("entry") or {}).get("text") or "")
    elif method == "Runtime.exceptionThrown":
        d = params.get("exceptionDetails") or {}
        line = f"[exception] {d.get('text') or d}"
    if line:
        append_log(console_log, line)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--chrome", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--wav", required=True)
    ap.add_argument("--user-data-dir", required=True)
    ap.add_argument("--seconds", type=float, default=15.0)
    ap.add_argument("--console-log", required=True)
    ap.add_argument("--devtools-port", type=int, default=0)
    args = ap.parse_args()

    port = args.devtools_port or (9400 + (os.getpid() % 400))
    os.makedirs(args.user_data_dir, exist_ok=True)
    open(args.console_log, "w", encoding="utf-8").close()

    # Pass the target URL on the command line so Chrome opens it as the initial tab.
    cmd = [
        args.chrome,
        "--headless=new",
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
        "--disable-gpu-sandbox",
        "--disable-gpu-compositing",
        "--disable-software-rasterizer",
        "--use-gl=disabled",
        "--in-process-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        f"--user-data-dir={args.user_data_dir}",
        "--use-fake-device-for-media-stream",
        "--use-fake-ui-for-media-stream",
        f"--use-file-for-fake-audio-capture={args.wav}",
        "--autoplay-policy=no-user-gesture-required",
        f"--remote-debugging-port={port}",
        "--remote-allow-origins=*",
        args.url,
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    page: CdpWs | None = None
    try:
        wait_json(f"http://127.0.0.1:{port}/json/version", timeout=30)

        def find_page() -> dict[str, Any] | None:
            try:
                for t in http_json(f"http://127.0.0.1:{port}/json/list"):
                    if t.get("type") != "page":
                        continue
                    url = t.get("url") or ""
                    if "mic-demo" in url or args.url.split("?")[0] in url:
                        return t
                # Fall back to any page with a debugger URL.
                for t in http_json(f"http://127.0.0.1:{port}/json/list"):
                    if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                        return t
            except Exception:
                return None
            return None

        target = None
        for i in range(80):
            target = find_page()
            if target and target.get("webSocketDebuggerUrl"):
                print(f"found target url={target.get('url')!r} (poll {i})", flush=True)
                break
            time.sleep(0.25)
        if not target or not target.get("webSocketDebuggerUrl"):
            # Dump list for diagnosis.
            try:
                print("json/list:", json.dumps(http_json(f"http://127.0.0.1:{port}/json/list"), indent=2)[:2000], file=sys.stderr)
            except Exception as e:  # noqa: BLE001
                print(f"json/list failed: {e}", file=sys.stderr)
            raise RuntimeError("no page target for mic-demo")

        page = CdpWs(target["webSocketDebuggerUrl"])
        for domain in ("Runtime.enable", "Page.enable", "Log.enable"):
            try:
                page.call(domain, timeout=5)
            except Exception as e:  # noqa: BLE001
                print(f"warn: {domain}: {e}", file=sys.stderr)

        try:
            href = (
                (
                    page.call(
                        "Runtime.evaluate",
                        {"expression": "location.href", "returnByValue": True},
                        timeout=5,
                    )
                    or {}
                ).get("result")
                or {}
            ).get("value")
            print(f"attached to {href}", flush=True)
        except Exception as e:  # noqa: BLE001
            print(f"warn: href eval: {e}", file=sys.stderr)

        deadline = time.time() + args.seconds
        while time.time() < deadline:
            for ev in page.recv_messages(0.5):
                handle_event(ev, args.console_log)
        print(f"cdp ok; console -> {args.console_log}", flush=True)
        return 0
    except Exception as e:  # noqa: BLE001
        print(f"cdp_run error: {e}", file=sys.stderr)
        try:
            if proc.stderr:
                # Non-blocking drain of whatever is available.
                try:
                    import select as _sel

                    r, _, _ = _sel.select([proc.stderr], [], [], 0.2)
                    if r:
                        err = proc.stderr.read()
                        if err:
                            sys.stderr.write(err.decode("utf-8", "replace")[:4000])
                except Exception:
                    pass
        except Exception:
            pass
        return 2
    finally:
        if page:
            page.close()
        try:
            proc.kill()
        except Exception:
            pass
        try:
            proc.wait(timeout=3)
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())

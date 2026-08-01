#!/usr/bin/env python3
"""Summarise the reports produced by `run.py`.

Takes one or more result files and prints, per condition, the median across runs of each
section together with a bootstrap confidence interval, so that a difference between two
conditions can be told apart from run-to-run noise.

    python3 analyze.py breakdown.json [more.json ...]
    python3 analyze.py --compare 2560x1440/real/real 2560x1440/real/memcpy *.json
"""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import sys
from collections import defaultdict

SECTIONS = ["events", "ui_build", "post_ui", "fb_clear", "canvas_composite",
            "canvas_blit", "overlays", "gui_render", "swizzle", "js_present",
            "post_present"]


def key_of(run: dict) -> str:
    c = run.get("conditions", {})
    return f"{c.get('w')}x{c.get('h')}/{c.get('present')}/{c.get('swizzle')}"


REQUIRED_CONDITION_FIELDS = ("w", "h", "present", "swizzle")
REQUIRED_ACTUAL_FIELDS = ("fb_w", "fb_h", "css_w", "css_h", "backing_w", "backing_h",
                          "dpr", "resize_events")
REQUIRED_RUN_FIELDS = ("frames", "host_frames", "raf_callback_ms", "sections_ms",
                       "js_present_split_ms", "residual_ms", "section_sum_ms",
                       "wasm_sha256")
REQUIRED_CALLBACK_FIELDS = ("mean", "median", "p95", "n")
REQUIRED_SPLIT_FIELDS = ("set", "put", "setup_calls")


def _finite(v: object) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def validate(run: dict) -> str | None:
    """Reasons this run must not be pooled with others. A run that measured something
    other than what it claims is worse than a missing run, so this is fail-closed: a
    field that is absent, non-numeric or not finite counts as a failed check, never as a
    passed one. Without this, a partial report silently loses values in `series()` and
    still produces a summary."""
    problems = []
    missing = [f for f in REQUIRED_RUN_FIELDS if run.get(f) is None]
    c = run.get("conditions") or {}
    a = run.get("actual") or {}
    missing += [f"conditions.{f}" for f in REQUIRED_CONDITION_FIELDS if c.get(f) is None]
    missing += [f"actual.{f}" for f in REQUIRED_ACTUAL_FIELDS if a.get(f) is None]
    # The nested blocks are what the summary actually reads, so they are checked as
    # closely as the top level.
    cb = run.get("raf_callback_ms") or {}
    sec = run.get("sections_ms") or {}
    spl = run.get("js_present_split_ms") or {}
    missing += [f"raf_callback_ms.{f}" for f in REQUIRED_CALLBACK_FIELDS if not _finite(cb.get(f))]
    missing += [f"sections_ms.{s}" for s in SECTIONS if not _finite(sec.get(s))]
    missing += [f"js_present_split_ms.{f}" for f in REQUIRED_SPLIT_FIELDS if not _finite(spl.get(f))]
    for f in ("frames", "host_frames", "residual_ms", "section_sum_ms"):
        if not _finite(run.get(f)):
            missing.append(f)
    if missing:
        return "missing or not a finite number: " + ", ".join(missing)
    if run["frames"] <= 0:
        return "no frames measured"

    want_w, want_h = int(c["w"]), int(c["h"])
    # The framebuffer follows the element's client box and is clamped to a minimum, so a
    # requested size is not necessarily the measured size.
    if (a["fb_w"], a["fb_h"]) != (want_w, want_h):
        problems.append(f"framebuffer {a['fb_w']}x{a['fb_h']} != requested {want_w}x{want_h}")
    # A backing store that differs from the CSS box means the browser resampled.
    if (a["backing_w"], a["backing_h"]) != (a["css_w"], a["css_h"]):
        problems.append(f"backing {a['backing_w']}x{a['backing_h']} "
                        f"!= css {a['css_w']}x{a['css_h']} (browser resampled)")
    if a["dpr"] != 1:
        problems.append(f"device pixel ratio {a['dpr']}")
    if a["resize_events"]:
        problems.append(f"{a['resize_events']} resize events during the window")
    # Frames the app ran vs animation frames that elapsed: a mismatch means something
    # else was driving frames (two app instances is the usual cause).
    if run["frames"] != run["host_frames"]:
        problems.append(f"app ran {run['frames']} frames over "
                        f"{run['host_frames']} animation frames")
    if run["js_present_split_ms"].get("setup_calls"):
        problems.append("ImageData was reallocated inside the measured window")
    return "; ".join(problems) if problems else None


def load(paths: list[str]) -> dict[str, list[dict]]:
    groups: dict[str, list[dict]] = defaultdict(list)
    builds: dict[str, set] = defaultdict(set)
    for p in paths:
        doc = json.loads(open(p).read())
        meta_sha = (doc.get("meta") or {}).get("wasm_sha256")
        for run in doc.get("runs", []):
            if run.get("error"):
                print(f"skip (error): {run.get('label')}: {run['error']}", file=sys.stderr)
                continue
            why = validate(run)
            if why:
                print(f"skip (invalid): {run.get('label')}: {why}", file=sys.stderr)
                continue
            # The per-run hash is what identifies the build; disagreeing with the file's
            # own metadata means the file was assembled by hand or edited.
            if run["wasm_sha256"] != meta_sha:
                print(f"skip (invalid): {run.get('label')}: run wasm hash "
                      f"{run['wasm_sha256'][:12]} != file metadata {str(meta_sha)[:12]}",
                      file=sys.stderr)
                continue
            key = key_of(run)
            groups[key].append(run)
            builds[key].add(run["wasm_sha256"])
    # Two builds under one condition cannot be pooled: the whole point of a condition is
    # that only the named axis differs.
    mixed = {k: v for k, v in builds.items() if len(v) > 1}
    if mixed:
        for k, shas in mixed.items():
            print(f"ERROR: {k} pools {len(shas)} different wasm builds: "
                  f"{', '.join(sorted(s[:12] for s in shas))}", file=sys.stderr)
        sys.exit("refusing to summarise across builds; analyse each build's results separately")
    return groups


def boot_ci(xs: list[float], iters: int = 4000, seed: int = 7) -> tuple[float, float]:
    """Percentile bootstrap CI of the median. Few runs per condition make the
    distribution-free interval the honest one to quote."""
    if len(xs) < 2:
        return (float("nan"), float("nan"))
    rng = random.Random(seed)
    meds = []
    for _ in range(iters):
        sample = [xs[rng.randrange(len(xs))] for _ in xs]
        meds.append(statistics.median(sample))
    meds.sort()
    return (meds[int(0.025 * iters)], meds[int(0.975 * iters)])


def series(runs: list[dict], path: list[str]) -> list[float]:
    out = []
    for r in runs:
        v: object = r
        for k in path:
            if not isinstance(v, dict) or k not in v:
                v = None
                break
            v = v[k]
        if isinstance(v, (int, float)):
            out.append(float(v))
    return out


def med(xs: list[float]) -> float:
    return statistics.median(xs) if xs else float("nan")


def summarise(key: str, runs: list[dict]) -> None:
    r0 = runs[0]
    act = r0.get("actual", {})
    print(f"\n=== {key}   n={len(runs)} runs, {r0.get('frames')} frames each")
    print(f"    actual fb {act.get('fb_w')}x{act.get('fb_h')}  css {act.get('css_w')}x{act.get('css_h')}"
          f"  backing {act.get('backing_w')}x{act.get('backing_h')}  dpr {act.get('dpr')}"
          f"  resize_events {act.get('resize_events')}")
    inst = r0.get("instrument", {})
    res_ms = inst.get("clock_resolution_ms", 0)
    print(f"    instrument: {inst.get('marks_per_frame')} marks/frame,"
          f" {inst.get('overhead_ms', 0) * 1000:.2f} us/frame overhead,"
          f" clock resolution {res_ms * 1000:.1f} us")

    cb = series(runs, ["raf_callback_ms", "mean"])
    lo, hi = boot_ci(cb)
    print(f"    rAF callback (mean per run)  {med(cb) * 1000:9.1f} us  [{lo * 1000:.1f}, {hi * 1000:.1f}]")
    gap = series(runs, ["raf_interval_ms", "median"])
    print(f"    rAF interval  (effective)    {med(gap) * 1000:9.1f} us")

    total = med(cb)
    print(f"    {'section':<18} {'us':>9} {'%':>6}   95% CI (us)")
    for s in SECTIONS:
        xs = series(runs, ["sections_ms", s])
        if not xs:
            continue
        m = med(xs)
        lo, hi = boot_ci(xs)
        flag = "  (< clock resolution)" if m < res_ms else ""
        pctv = 100 * m / total if total else 0
        print(f"    {s:<18} {m * 1000:9.1f} {pctv:5.1f}%   [{lo * 1000:.1f}, {hi * 1000:.1f}]{flag}")
    ssum = series(runs, ["section_sum_ms"])
    resid = series(runs, ["residual_ms"])
    print(f"    {'sum':<18} {med(ssum) * 1000:9.1f} {100 * med(ssum) / total if total else 0:5.1f}%")
    print(f"    {'residual':<18} {med(resid) * 1000:9.1f} {100 * med(resid) / total if total else 0:5.1f}%")

    sset = series(runs, ["js_present_split_ms", "set"])
    sput = series(runs, ["js_present_split_ms", "put"])
    setup = series(runs, ["js_present_split_ms", "setup_calls"])
    if sset and med(sset) + med(sput) > 0:
        print(f"    js present split: set {med(sset) * 1000:.1f} us,"
              f" putImageData {med(sput) * 1000:.1f} us,"
              f" setup calls in window {med(setup):.0f}")


def compare(groups: dict[str, list[dict]], a: str, b: str) -> None:
    if a not in groups or b not in groups:
        sys.exit(f"unknown condition: {a if a not in groups else b}")
    print(f"\n### {a}  vs  {b}")
    # Which build each side came from. Pooling two builds inside one condition is already
    # refused; across two conditions it is legitimate (that is how a compiler flag is
    # compared), but it changes what the difference means, so it is stated rather than
    # assumed either way.
    # Compared in full; shown abbreviated.
    sa = {r["wasm_sha256"] for r in groups[a]}
    sb = {r["wasm_sha256"] for r in groups[b]}
    same = "same build" if sa == sb else "DIFFERENT BUILDS"
    short = lambda s: ",".join(sorted(x[:12] for x in s))
    print(f"    build A {short(sa)}  build B {short(sb)}  ({same})")
    print(f"    {'section':<18} {'A us':>9} {'B us':>9} {'A-B us':>9}   95% CI of A-B")
    rows = [("rAF callback", ["raf_callback_ms", "mean"])] + \
           [(s, ["sections_ms", s]) for s in SECTIONS]
    for name, path in rows:
        xa, xb = series(groups[a], path), series(groups[b], path)
        if not xa or not xb:
            continue
        # Unpaired: the runs are independent browser launches, so the difference of
        # medians is resampled from both sides.
        rng = random.Random(13)
        diffs = []
        for _ in range(4000):
            sa = [xa[rng.randrange(len(xa))] for _ in xa]
            sb = [xb[rng.randrange(len(xb))] for _ in xb]
            diffs.append(statistics.median(sa) - statistics.median(sb))
        diffs.sort()
        lo, hi = diffs[100], diffs[3899]
        d = med(xa) - med(xb)
        mark = "" if lo <= 0 <= hi else "  *"
        print(f"    {name:<18} {med(xa) * 1000:9.1f} {med(xb) * 1000:9.1f} {d * 1000:9.1f}"
              f"   [{lo * 1000:.1f}, {hi * 1000:.1f}]{mark}")
    print("    * = interval excludes zero")


def check_split_fidelity(groups: dict[str, list[dict]]) -> bool:
    """The `split` condition reimplements the host present so its two halves can be timed.
    That is only meaningful while the reimplementation still matches the real one, which
    is checked by comparing its total against the real condition's `js_present`.

    A condition that fails is dropped from `groups` and reported, because a split whose
    total no longer matches is a wrong breakdown, not a noisy one. Returns whether any
    failed, so the caller can exit non-zero."""
    printed = False
    failed = []
    for key, runs in list(groups.items()):
        size, present, swizzle = key.split("/")
        if present != "split":
            continue
        base = groups.get(f"{size}/real/{swizzle}")
        if not base:
            # Without the untouched path to compare against, the split cannot be shown
            # to still reproduce it, so its breakdown is not usable.
            failed.append(key)
            del groups[key]
            continue
        split_total = med(series(runs, ["js_present_split_ms", "set"])) + \
            med(series(runs, ["js_present_split_ms", "put"]))
        real_total = med(series(base, ["sections_ms", "js_present"]))
        if not real_total:
            continue
        drift = abs(split_total - real_total) / real_total
        if not printed:
            print("\n### split-vs-real fidelity (the split is only readable while these agree)")
            printed = True
        # A relative threshold alone cries wolf on a section only a few clock ticks wide,
        # so an absolute floor has to be cleared too.
        big = abs(split_total - real_total) * 1000 > 50
        bad = drift > 0.15 and big
        flag = "  MISMATCH (dropped)" if bad else ""
        if bad:
            failed.append(key)
            del groups[key]

        print(f"    {size:12} split set+put {split_total * 1000:8.1f} us   "
              f"real js_present {real_total * 1000:8.1f} us   drift {drift * 100:5.1f}%{flag}")
    for key in failed:
        print(f"ERROR: {key} no longer reproduces the real present; its split is not usable",
              file=sys.stderr)
    return bool(failed)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--compare", nargs=2, metavar=("A", "B"), action="append", default=[])
    args = ap.parse_args()
    groups = load(args.files)
    # Before anything is printed: a split condition that no longer reproduces the real
    # present is dropped here, so no invalid breakdown reaches the output at all.
    split_failed = check_split_fidelity(groups)
    for key in sorted(groups, key=lambda k: (int(k.split("x")[0]), k)):
        summarise(key, groups[key])
    for a, b in args.compare:
        compare(groups, a, b)
    if split_failed:
        sys.exit("a split condition diverged from the real present path")


if __name__ == "__main__":
    main()

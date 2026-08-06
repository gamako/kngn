#!/usr/bin/env python3
"""Generate a short mono 48 kHz 16-bit sine WAV for headless Chrome fake mic capture.

Usage:
  python3 tests/e2e/gen_fake_mic_wav.py [out.wav]

Default out path: tests/e2e/fake-mic-440hz.wav (created next to this script).
Not checked into the repo as a binary — always generate before the e2e script runs.
"""

from __future__ import annotations

import math
import struct
import sys
import wave
from pathlib import Path

SAMPLE_RATE = 48000
DURATION_S = 4.0
FREQ_HZ = 440.0
AMPLITUDE = 0.35  # of full-scale int16


def main() -> int:
    here = Path(__file__).resolve().parent
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else here / "fake-mic-440hz.wav"
    nframes = int(SAMPLE_RATE * DURATION_S)

    out.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(out), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        # Write in chunks to avoid a huge intermediate list.
        chunk = 4096
        for base in range(0, nframes, chunk):
            end = min(base + chunk, nframes)
            buf = bytearray()
            for i in range(base, end):
                t = i / SAMPLE_RATE
                s = math.sin(2.0 * math.pi * FREQ_HZ * t)
                sample = int(max(-1.0, min(1.0, s * AMPLITUDE)) * 32767.0)
                buf += struct.pack("<h", sample)
            w.writeframes(buf)

    print(f"wrote {out} ({nframes} frames, {SAMPLE_RATE} Hz mono 16-bit, {FREQ_HZ} Hz sine)", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

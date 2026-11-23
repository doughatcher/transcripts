#!/usr/bin/env python3
"""Look for shared signal in saved mic/system tracks (macOS, offline).

Requires numpy and scipy in the invoking Python environment. Uses afconvert for
AAC/CAF decoding. This detects shared audio, not its cause or audible severity.
Example: python scripts/audit-call-audio.py '/path/to/captures/<UUID>'
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import warnings

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, correlate, sosfilt

RATE = 8000


def match(mic, system, start, seconds=10, max_lag=10):
    a = int(start * RATE)
    x = mic[a:a + seconds * RATE]
    lo = max(0, a - max_lag * RATE)
    y = system[lo:min(len(system), a + len(x) + max_lag * RATE)]
    power = np.dot(x, x)
    if len(x) < seconds * RATE or len(y) < len(x) or power < len(x) * 1e-10:
        return None
    cross = correlate(y, x, mode="valid", method="fft")
    sums = np.r_[0, np.cumsum(y * y)]
    energy = sums[len(x):] - sums[:-len(x)]
    # FFT roundoff in digital silence must not become a giant false correlation.
    valid = energy > len(x) * 1e-8
    scores = np.divide(cross, np.sqrt(np.maximum(1e-20, energy * power)),
                       out=np.zeros_like(cross), where=valid)
    k = int(np.argmax(abs(scores)))
    # Recompute the winning score directly, avoiding cumsum cancellation.
    candidate = y[k:k + len(x)]
    denominator = np.linalg.norm(x) * np.linalg.norm(candidate)
    score = float(np.dot(x, candidate) / denominator) if denominator else 0
    return {"micStartSeconds": start, "correlation": round(score, 4),
            "systemMinusMicIndexMilliseconds": round((lo + k - a) / RATE * 1000, 3),
            "micRMS": round(float(np.sqrt(power / len(x))), 7)}


def source(directory, names):
    for name in names:
        path = directory / name
        if path.exists():
            return path
    raise ValueError(f"No separate track in {directory}: expected one of {names}")


def decode(path, target):
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}",
                    "-c", "1", str(path), str(target)], check=True, capture_output=True)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", wavfile.WavFileWarning)
        rate, samples = wavfile.read(target)
    assert rate == RATE
    filtered = sosfilt(butter(4, [250, 3000], fs=RATE, btype="bandpass", output="sos"),
                       samples.astype(float) / 32768)
    return filtered


def self_test():
    rng = np.random.default_rng(42)
    mic = rng.normal(0, 0.05, 30 * RATE)
    system = np.r_[np.zeros(1000), mic[:-1000]]
    found = match(mic, system, 10)
    assert found["correlation"] > 0.99, found
    assert found["systemMinusMicIndexMilliseconds"] == 125, found
    assert abs(match(mic, rng.normal(0, 0.05, len(mic)), 10)["correlation"]) < 0.1
    assert match(np.zeros_like(mic), system, 10) is None
    assert abs(match(mic, np.zeros_like(system), 10)["correlation"]) == 0
    print("Passed delayed-copy, unrelated-signal, and silence checks.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, nargs="?")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.capture is None:
        parser.error("supply a capture directory or --self-test")
    mic_file = source(args.capture, ["meeting-mic.m4a", "audio.caf"])
    sys_file = source(args.capture, ["meeting-system.m4a", "system.caf"])
    with tempfile.TemporaryDirectory(prefix="call-audio-audit-") as temp:
        mic = decode(mic_file, Path(temp) / "mic.wav")
        system = decode(sys_file, Path(temp) / "system.wav")
        windows = [match(mic, system, t) for t in range(10, int(min(len(mic), len(system)) / RATE) - 10, 30)]
        windows = [w for w in windows if w is not None]
        strong = [w for w in windows if abs(w["correlation"]) >= 0.3]
        result = {"captureID": args.capture.name, "micFile": mic_file.name, "systemFile": sys_file.name,
                  "micSeconds": len(mic) / RATE, "systemSeconds": len(system) / RATE,
                  "sampledWindows": len(windows), "strongMatches": len(strong),
                  "matches": strong, "bestWindows": sorted(windows, key=lambda w: abs(w["correlation"]), reverse=True)[:5],
                  "caveat": "Sampled shared-signal evidence; not a full recording verdict. Lag is on stored file timelines, which may include assembly offsets."}
    text = json.dumps(result, indent=2)
    if args.output:
        args.output.write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    main()

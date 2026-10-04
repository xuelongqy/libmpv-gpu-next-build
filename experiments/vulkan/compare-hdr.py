"""Compare native HDR targets without reducing them to 8-bit screenshots."""
import json
from pathlib import Path
import subprocess
import sys

import numpy as np

root = Path(sys.argv[1])
pair = sys.argv[2:3] == ["--pair"]
assert sys.argv[2:] in ([], ["--offscreen-only"]) or (pair and len(sys.argv) in (5, 6))
offscreen_only = "--offscreen-only" in sys.argv[2:]
results = []


def raw(path):
    info = json.loads(Path(str(path) + ".json").read_text())
    h, w, fmt = info["height"], info["width"], info["format"]
    if fmt == 97:  # R16G16B16A16_SFLOAT
        values = np.fromfile(path, dtype="<f2").reshape(h, w, 4)[..., :3]
        assert np.isfinite(values).all()
        return values
    assert fmt in (58, 64)
    packed = np.fromfile(path, dtype="<u4").reshape(h, w)
    channels = (2, 1, 0) if fmt == 58 else (0, 1, 2)
    return np.stack([(packed >> (10*c)) & 1023 for c in channels], axis=-1).astype(np.int32)


def png10(path, shape):
    data = subprocess.check_output([
        "ffmpeg", "-v", "error", "-i", str(path), "-f", "rawvideo",
        "-pix_fmt", "rgb48le", "-frames:v", "1", "-",
    ])
    samples = np.frombuffer(data, dtype="<u2").reshape(shape)
    return np.rint(samples.astype(np.float64) * 1023 / 65535).astype(np.int32)


def compare(left, right, fp16=False):
    a = raw(root / left)
    b = png10(root / right, a.shape) if right.endswith(".png") else raw(root / right)
    assert a.shape == b.shape
    if fp16:
        # Monotonic half-float codes; +0 and -0 share the same position.
        def ordered(value):
            bits = value.view(np.uint16).astype(np.int32)
            return np.where(bits & 32768, 32768 - (bits & 32767), 32768 + bits)
        delta = int(np.abs(ordered(a) - ordered(b)).max())
        unit = "FP16_ULP"
    else:
        delta = int(np.abs(a - b).max())
        unit = "10-bit code"
    results.append(dict(left=left, right=right, maximum=delta, unit=unit, passed=delta <= 1))


if pair:
    assert sys.argv[5:] in ([], ["--fp16"])
    compare(sys.argv[3], sys.argv[4], fp16=sys.argv[5:] == ["--fp16"])
    print(json.dumps(results, indent=2))
    raise SystemExit(0 if results[0]["passed"] else 1)

for sample in ("sdr", "hdr10", "dv-p5"):
    prefix = f"pq-{sample}"
    if not offscreen_only:
        compare(prefix + "-offscreen.raw", prefix + "-window.raw")
    compare(prefix + "-offscreen.raw", prefix + "-offscreen.png")
    compare(prefix + "-offscreen.raw", "ref-" + prefix + ".png")
    if not offscreen_only:
        compare(f"scrgb-{sample}-offscreen.raw", f"scrgb-{sample}-window.raw", fp16=True)

compare("bgr10.raw", "pq-hdr10-offscreen.raw" if offscreen_only else "pq-hdr10-window.raw")
if not offscreen_only:
    compare("calibration-2020-r2.raw", "calibration-window.raw", fp16=True)
    compare("calibration-wide-offscreen.raw", "calibration-wide-window.raw", fp16=True)
for mode in ("pq", "scrgb"):
    for target in (("offscreen",) if offscreen_only else ("offscreen", "window")):
        prefix = f"stress-{mode}-{target}.png-skip-"
        for n in range(20):
            capture = prefix + f"{n:02}.raw"
            info = json.loads((root / (capture + ".json")).read_text())
            assert abs(info["pts"] - (2 if n % 2 else 3)) < 0.05
            if mode == "pq":
                compare(capture, prefix + f"{n:02}.png")
            elif n >= 2:
                compare(capture, prefix + f"{n % 2:02}.raw", fp16=True)

print(json.dumps(results, indent=2))
raise SystemExit(0 if all(r["passed"] for r in results) else 1)

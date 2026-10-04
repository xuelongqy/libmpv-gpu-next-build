"""Raw pixels only: do not apply ICC/color-management to encoded screenshots."""
import json
from pathlib import Path
import sys
import numpy as np
from PIL import Image

root = Path(sys.argv[1])
results = []
def compare(a, b, flip=False):
    x = np.array(Image.open(root/a).convert("RGB")).astype(np.int16)
    y = np.array(Image.open(root/b).convert("RGB")).astype(np.int16)
    if flip:
        y = y[::-1]
    delta = int(np.abs(x-y).max()) if x.shape == y.shape else None
    results.append({"a": a, "b": b, "flip": flip, "max_error": delta,
                    "pass": delta is not None and delta <= 1})
if sys.argv[2:]:
    assert len(sys.argv) == 5 and sys.argv[2] == "--pair"
    compare(sys.argv[3], sys.argv[4])
    print(json.dumps(results, indent=2))
    raise SystemExit(0 if results[0]["pass"] else 1)
for name in ("sdr", "hdr10", "dv-p5"):
    compare(name+".ppm", name+".png")
    compare(name+".png", "ref-"+name+".png")
    compare(name+".ppm", "window-"+name+".ppm")
    compare("window-"+name+".ppm", "window-"+name+".png")
compare("flip.ppm", "sdr.ppm", flip=True)
for prefix in ("lifecycle", "window-lifecycle"):
    for n in range(20):
        compare(f"{prefix}.png-skip-{n:02}.png", f"{prefix}.png-skip-{n:02}.ppm")
print(json.dumps(results, indent=2))
raise SystemExit(0 if all(r["pass"] for r in results) else 1)

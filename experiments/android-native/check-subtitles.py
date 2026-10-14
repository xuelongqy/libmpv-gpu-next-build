"""Check native subtitle pixels from accepted Android cases."""
import json
from pathlib import Path
import sys

if not __debug__:
    raise SystemExit("Run without Python optimization; this check relies on assertions.")

import numpy as np
from PIL import Image

if len(sys.argv) < 3:
    raise SystemExit("usage: check-subtitles.py RESULTS_DIR CASE_NAME [CASE_NAME ...]")
root = Path(sys.argv[1]).resolve()
results = []
for name in sys.argv[2:]:
    report = json.loads((root / f"{name}.result.json").read_text())
    assert report["status"] == "pass", name
    assert report["initial"]["current-vo"] == "mediacodec_embed", name
    pgs = "Using subtitle decoder pgssub" in (root / f"{name}.stream.log").read_text(errors="replace")
    entries = report["subtitle_checks"]
    assert entries and any(entry["visible"] for entry in entries), name
    for entry in entries:
        pixels = np.asarray(Image.open(root / entry["image"]).convert("RGBA"))
        alpha = pixels[:, :, 3]
        if not entry["visible"]:
            assert not np.any(alpha), (name, entry)
            continue
        assert np.count_nonzero(alpha == 0) > alpha.size * .75, (name, entry)
        assert np.any((alpha > 0) & (alpha < 255)), (name, entry)
        if pgs:
            opaque = pixels[alpha == 255, :3].astype(int)
            assert np.any(np.all(opaque >= 253, axis=1)), name
            assert np.any(np.all(np.abs(opaque - (25, 255, 255)) <= 1, axis=1)), name
            assert np.any((alpha >= 127) & (alpha <= 129)), name
    if report["hdmi_samples"] and report["sample"] == "dv":
        assert report["hdmi_samples"] and all(sample["hdr"] == "DolbyVision-Std"
            for sample in report["hdmi_samples"]), name
    results.append(dict(case=name, status="pass", screenshots=len(entries),
                        lifecycle=len(report.get("lifecycle", [])), pgs_palette_checked=pgs))
    print(f"{name}: PIXELS_ALPHA=PASS PGS_PROBES={'PASS' if pgs else 'not_applicable'} screenshots={len(entries)}")
assert results, "provide case names"
(root / "subtitle-pixel-check.json").write_text(json.dumps(results, indent=2) + "\n")

"""Check this run's native long-play evidence; no device or source mutations."""
import json
import sys
from pathlib import Path

if not __debug__:
    raise SystemExit("Run without Python optimization; this check relies on assertions.")

if len(sys.argv) != 2:
    raise SystemExit("usage: check-long.py EVIDENCE_DIRECTORY")
root = Path(sys.argv[1])
expected = (root / "media-long.sha256").read_text().split()[0]
results = {}
for platform, ao in (("macos", "avfoundation"), ("ios", "audiounit")):
    prefix = f"{platform}-native-900" + ("-r2" if platform == "ios" else "")
    case = json.loads((root / f"{prefix}.json").read_text())
    report = json.loads((root / f"{prefix}-report.json").read_text())
    assert case["status"] == "pass" and case["exit_code"] == report["exit_code"] == 0
    assert report["errors"] == 0 and report["audio"] and report["input_sha256"] == expected
    samples = report["progress"]
    assert len(samples) >= 850 and samples[-1]["elapsed"] >= 900
    assert samples[-1]["time-pos"] - samples[0]["time-pos"] >= 898.5
    assert all(s["output_mode"] == "native" and s["hwdec-current"] == "videotoolbox"
               and s["current-ao"] == ao and s["volume"] == 50 for s in samples)
    steady = [s for s in samples if s["elapsed"] >= 5]
    sync_run = video_run = audio_run = 0
    for previous, sample in zip(steady, steady[1:]):
        dt = sample["elapsed"] - previous["elapsed"]
        assert 0 < dt < 5, "Missing steady-state observation interval"
        sync_run = sync_run + dt if abs(sample["avsync"]) > .100 else 0
        video_run = video_run + dt if sample["time-pos"] <= previous["time-pos"] else 0
        audio_run = audio_run + dt if sample["audio-pts"] <= previous["audio-pts"] else 0
        assert max(sync_run, video_run, audio_run) < 5
    metrics = {"evidence_prefix": prefix,
               "steady_max_abs_avsync_seconds": max(abs(s["avsync"]) for s in steady),
               "final_vo_drops": samples[-1].get("frame-drop-count"),
               "final_decoder_drops": samples[-1].get("decoder-frame-drop-count"),
               "elapsed_seconds": samples[-1]["elapsed"], "samples": len(samples)}
    available = [s for s in samples if s["elapsed"] >= 60 and "resident_bytes" in s
                 and "cpu_seconds" in s and "footprint_bytes" in s]
    if available:
        first, last = available[0], available[-1]
        metrics.update(cpu_core_average=(last["cpu_seconds"] - first["cpu_seconds"]) /
                       (last["elapsed"] - first["elapsed"]),
                       resident_first=first["resident_bytes"], resident_last=last["resident_bytes"],
                       resident_peak=max(s["resident_bytes"] for s in available),
                       footprint_first=first["footprint_bytes"], footprint_last=last["footprint_bytes"])
    else:
        metrics["resources"] = "unavailable"
    results[platform] = metrics
print(json.dumps(results, indent=2))

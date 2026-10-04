"""Check the existing PQ stress artifacts, including actual target readbacks."""
import json
from pathlib import Path
import re
import subprocess
import sys

root, prefix = Path(sys.argv[1]), sys.argv[2]
record = json.loads((root / (prefix + ".json")).read_text())
assert record["exit_code"] == 0 and record["status"] == "pass"
log = (root / (prefix + ".log")).read_text(errors="replace")
for marker in ("RESIZES=100 PASS", "LOADS=20 PASS", "SKIP_SCREENSHOT_CYCLES=20 PASS"):
    assert marker in log, marker
assert re.findall(r"VALIDATION_ERRORS=(\d+)", log) == ["0"]
assert "PLAYBACK_ERROR=" not in log
assert log.count("PIXELS=PASS EXPECT=0") >= 2
segments = re.findall(r"PLAY_DURATION_MS=(\d+) REQUESTED_SECONDS=(\d+) RESULT=(\d+)", log)
assert len(segments) == 42 and [int(row[1]) for row in segments] == [10] + [2] * 41
assert all(int(ms) >= int(seconds) * 1000 and result == "0" for ms, seconds, result in segments)
restarts = re.findall(r"SEEK_RESTART=(\d+) SKIPPED_FRAMES=(\d+) PTS=([\d.]+)", log)
assert [int(row[0]) for row in restarts] == list(range(20))
assert all(int(row[1]) > 0 for row in restarts)

comparer = Path(__file__).resolve().parent / "compare-hdr.py"
results = []
for n in range(20):
    name = f"{prefix}.png-skip-{n:02}"
    info = json.loads((root / (name + ".raw.json")).read_text())
    assert abs(info["pts"] - (2 if n % 2 else 3)) < 0.05, info
    check = subprocess.run([sys.executable, str(comparer), str(root), "--pair",
                            name + ".raw", name + ".png"],
                           capture_output=True, text=True, timeout=15)
    results.append(dict(cycle=n, exit_code=check.returncode,
                        comparison=json.loads(check.stdout) if check.stdout.strip() else None,
                        error=check.stderr))
print(json.dumps(results, indent=2))
raise SystemExit(0 if all(row["exit_code"] == 0 for row in results) else 1)

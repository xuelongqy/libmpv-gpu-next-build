"""Bounded delivery cases using the existing client and pixel comparers."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("stage", choices=("matrix", "controls", "lifecycle", "av"))
parser.add_argument("--samples", type=Path)
parser.add_argument("--baseline", type=Path)
parser.add_argument("--media", type=Path)
parser.add_argument("--audio-device")
parser.add_argument("--display", type=int)
args = parser.parse_args()
if args.stage == "matrix" and (not args.samples or not args.baseline):
    parser.error("matrix requires --samples and --baseline; no missing-reference pass")
if args.stage in ("av", "lifecycle") and (not args.media or not args.audio_device):
    parser.error("voiced checks require --media and an explicit --audio-device")
work = Path(os.environ.get("WORK_ROOT", here.parents[1]/".work/vulkan")).resolve()
(work/"evidence").mkdir(parents=True, exist_ok=True)
result = Path(tempfile.mkdtemp(prefix=args.stage+".", dir=work/"evidence"))
hardware = "d3d11va-copy" if os.name == "nt" else "videotoolbox-copy"
records = []


def run(name, seconds, command):
    status = subprocess.call([sys.executable, str(here/"case.py"), str(result/name), str(seconds), "--", *map(str, command)])
    record = dict(name=name, exit_code=status)
    if status == 0:
        log = (result/(name+".log")).read_text(errors="replace")
        if re.findall(r"VALIDATION_ERRORS=(\d+)", log) != ["0"]:
            record.update(exit_code=1, error="missing or nonzero validation result")
    records.append(record)
    (result/"summary.json").write_text(json.dumps(records, indent=2)+"\n")
    return record


def compare(record, command, timeout, exit_key):
    try:
        check = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                               errors="replace", timeout=timeout)
        code, stdout, stderr = check.returncode, check.stdout, check.stderr
    except subprocess.TimeoutExpired as error:
        code = 124
        # Timeout output can be bytes even when text=True.
        stdout, stderr = [value.decode(errors="replace") if isinstance(value, bytes) else value or ""
                          for value in (error.stdout, error.stderr)]
        stderr = f"Comparison timed out after {error.timeout} seconds.\n{stderr}"
    except OSError as error:
        code, stdout, stderr = 2, "", str(error)
    record.update({exit_key: code}, comparison=stdout, comparison_error=stderr)
    if code:
        record["exit_code"] = 1
    (result/"summary.json").write_text(json.dumps(records, indent=2)+"\n")


def smoke(*params):
    return ["bash", str(here/"run.sh"),
            *(["--display", str(args.display)] if args.display is not None else []), *map(str, params)]


if args.stage == "matrix":
    for sample in ("sdr", "hdr10", "dv-p5"):
        for output in ("sdr", "pq", "scrgb"):
            for target in ("offscreen", "window"):
                name = f"no-{output}-{sample}-{target}"
                ext = ".ppm" if output == "sdr" else ".raw"
                capture = result/(name+ext)
                record = run(name, 30, smoke("--hwdec", "no", "--output", output,
                             "--timeline" if target == "offscreen" else "--window",
                             "--capture", capture, "--screenshot", result/(name+".png"),
                             args.samples/(sample+"-20s.mkv")))
                if record["exit_code"] == 0:
                    comparer = here/("compare-sdr.py" if output == "sdr" else "compare-hdr.py")
                    compare(record, [sys.executable, str(comparer), str(result), "--pair",
                                     str(capture), str((args.baseline/(name+ext)).resolve()),
                                     *(["--fp16"] if output == "scrgb" else [])],
                            20, "comparison_exit")
elif args.stage == "controls":
    for name, seconds, params in (("probe", 30, ["--probe"]), ("fault", 30, ["--fault"]),
                                 ("contexts", 300, ["--contexts", "50"])):
        run(name, seconds, smoke(*params))
else:
    name = hardware+"-pq"
    params = ["--window", "--output", "pq", "--hwdec", hardware,
              "--play-seconds", "10" if args.stage == "lifecycle" else "60",
              "--audio-device", args.audio_device, "--volume", "50"]
    if args.stage == "lifecycle":
        params += ["--stress", "--screenshot", str(result/(name+".png"))]
    record = run(name, 300 if args.stage == "lifecycle" else 120, smoke(*params, args.media))
    if args.stage == "lifecycle" and record["exit_code"] == 0:
        compare(record, [sys.executable, str(here/"check-lifecycle.py"), str(result), name],
                120, "pixel_exit")
(result/"summary.json").write_text(json.dumps(records, indent=2)+"\n")
print(f"RESULT_DIR={result}", flush=True)
raise SystemExit(1 if any(r["exit_code"] not in (0, 77) for r in records) else
                 77 if any(r["exit_code"] == 77 for r in records) else 0)

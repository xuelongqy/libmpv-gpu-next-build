"""Run one smoke command with an external deadline and retain its evidence."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import time
from process_usage import read_usage

if len(sys.argv) < 5 or sys.argv[3] != "--":
    raise SystemExit("usage: case.py OUTPUT_PREFIX TIMEOUT -- COMMAND [ARGS...]")
output, limit, command = Path(sys.argv[1]), float(sys.argv[2]), sys.argv[4:]
if any(Path(str(output) + suffix).exists() for suffix in (".log", ".json")):
    raise SystemExit("case output already exists; use a fresh prefix")
command[0] = shutil.which(command[0]) or command[0]
output.parent.mkdir(parents=True, exist_ok=True)
record = {
    "command": command, "cwd": os.getcwd(),
    "started": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "timeout_seconds": limit, "inputs_sha256": {},
}
for arg in command:
    path = Path(arg)
    if path.suffix.lower() in (".mkv", ".mp4") and path.is_file():
        with path.open("rb") as stream:
            record["inputs_sha256"][str(path.resolve())] = hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()
begin = time.monotonic()
sample_resources = os.environ.get("SMOKE_SAMPLE_RESOURCES") == "1"
usage = []
environment = dict(os.environ)
if os.name == "nt":
    # MSYS startup globbing would strip braces from literal WASAPI device IDs.
    environment["MSYS"] = environment.get("MSYS", "") + " noglob"
with Path(str(output) + ".log").open("wb") as log:
    try:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=os.name != "nt", env=environment)
        try:
            while True:
                remaining = limit - (time.monotonic() - begin)
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, limit)
                try:
                    record["exit_code"] = process.wait(timeout=min(1, remaining))
                    break
                except subprocess.TimeoutExpired:
                    if sample_resources:
                        try:
                            sample = read_usage(process.pid)
                        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                            sample = dict(unavailable=str(error))
                        usage.append(dict(elapsed_seconds=time.monotonic() - begin,
                                          pid=process.pid, counters=sample))
            record["status"] = ("pass" if record["exit_code"] == 0 else
                                "unsupported" if record["exit_code"] == 77 else "fail")
        except subprocess.TimeoutExpired:
            record.update(status="timeout", exit_code=124)
            if os.name == "nt":
                try:
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                   stdout=log, stderr=subprocess.STDOUT, check=False, timeout=5)
                except subprocess.TimeoutExpired:
                    record["tree_cleanup_timed_out"] = True
            else:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                record["cleanup_incomplete_pid"] = process.pid
    except (OSError, subprocess.TimeoutExpired) as error:
        record.update(status="unavailable", exit_code=2, error=str(error))
record["elapsed_seconds"] = round(time.monotonic() - begin, 3)
if sample_resources:
    record["process_usage"] = usage
Path(str(output) + ".json").write_text(json.dumps(record, indent=2) + "\n")
print(f'{output.name}: {record["status"]} ({record["elapsed_seconds"]}s)', flush=True)
raise SystemExit(record["exit_code"])

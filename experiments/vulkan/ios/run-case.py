"""Require the app completion marker; a successful device launcher is not a pass."""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

BUNDLE = "io.xuelongqy.libmpv.vulkan.smoke"
CASE = Path(__file__).resolve().parent.parent / "case.py"


def application_exit(launcher_exit, log, case_id, contexts=1):
    if launcher_exit:
        return launcher_exit
    if "IOS_UNSUPPORTED=" in log:
        return 77
    if "IOS_SETUP_ERROR=" in log:
        return 2
    lines = log.splitlines()
    completed = sum(line.startswith("IOS_RESULT=PASS ") and "CASE_ID=" + case_id in line.split()
                    for line in lines)
    final = f"IOS_CONTEXTS={contexts} PASS CASE_ID={case_id}"
    return 0 if completed == contexts and final in lines and "FAIL line=" not in log else 1


def main():
    if sys.argv[1:] == ["--self-check"]:
        one = "IOS_RESULT=PASS MEDIA=sdr CASE_ID=test\n"
        done = one + "IOS_CONTEXTS=1 PASS CASE_ID=test\n"
        assert application_exit(0, "app aborted", "test") == 1
        assert application_exit(0, one, "test") == 1
        assert application_exit(0, done, "test") == 0
        assert application_exit(124, done, "test") == 124
        assert application_exit(0, "VK_FAIL line=1\n" + done, "test") == 1
        assert application_exit(0, "IOS_UNSUPPORTED=metal_objects", "test") == 77
        assert application_exit(0, "IOS_SETUP_ERROR=matching_validation_loader_required", "test") == 2
        assert application_exit(0, done, "other") == 1
        assert application_exit(0, done, "test", 20) == 1
        twenty = one * 20 + "IOS_CONTEXTS=20 PASS CASE_ID=test\n"
        assert application_exit(0, twenty, "test", 20) == 0
        assert application_exit(0, one * 19 + "IOS_CONTEXTS=20 PASS CASE_ID=test\n", "test", 20) == 1
        assert application_exit(0, twenty.replace("CASE_ID=test", "CASE_ID=test-extra"), "test", 20) == 1
        print("IOS_RUNNER_SELF_CHECK=PASS")
        return 0
    if len(sys.argv) < 5 or sys.argv[3] != "--" or float(sys.argv[2]) <= 0:
        raise SystemExit("usage: run-case.py PREFIX TIMEOUT -- APP_ARGS...")
    output, limit, args = Path(sys.argv[1]), sys.argv[2], sys.argv[4:]
    contexts = 1
    for arg in args:
        if arg.startswith("--contexts="):
            contexts = int(arg.split("=", 1)[1])
    if not 1 <= contexts <= 20:
        raise SystemExit("contexts must be between 1 and 20")
    if Path(str(output) + ".json").exists():
        raise SystemExit("case output exists; choose a fresh prefix")
    device, simulator = os.environ.get("IOS_DEVICE"), os.environ.get("IOS_SIMULATOR")
    if bool(device) == bool(simulator):
        raise SystemExit("set exactly one of IOS_DEVICE or IOS_SIMULATOR")
    case_id = uuid.uuid4().hex
    args = [*args, "--case-id=" + case_id]
    launcher = Path(str(output) + "-launcher")
    launch = (["xcrun", "devicectl", "device", "process", "launch", "--console", "--terminate-existing",
               "--device", device, BUNDLE] if device else
              ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", simulator, BUNDLE])
    subprocess.run([sys.executable, str(CASE), str(launcher), limit, "--", *launch, *args], check=False)
    record = json.loads(Path(str(launcher) + ".json").read_text())
    log = Path(str(launcher) + ".log").read_text(errors="replace")
    record["launcher_exit_code"] = record["exit_code"]
    record["exit_code"] = application_exit(record["exit_code"], log, case_id, contexts)
    if record["launcher_exit_code"] == 0 and record["exit_code"] == 1:
        record["error"] = "app failed or did not complete all requested contexts for this test case"
    record.update(app_args=args, validation="not_enabled", log=str(launcher) + ".log")
    if device and record["exit_code"] == 0:
        try:
            copy = subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", device,
                "--source", "Documents/" + case_id, "--destination", str(output) + "-images",
                "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE, "--timeout", "30"],
                capture_output=True, text=True, timeout=40, check=False)
            record["copy_exit"] = copy.returncode
            if copy.returncode:
                record.update(exit_code=1, copy_error=copy.stdout + copy.stderr)
        except (OSError, subprocess.TimeoutExpired) as error:
            record.update(exit_code=1, copy_error=str(error))
    if record["exit_code"]:
        try:
            if device:
                processes = subprocess.run(["xcrun", "devicectl", "device", "info", "processes",
                    "--device", device, "--search", "IOSSmoke", "--json-output", "-", "--timeout", "5"],
                    capture_output=True, text=True, timeout=10, check=True)
                for process in json.loads(processes.stdout)["result"]["runningProcesses"]:
                    if process["executable"].endswith("/IOSSmoke.app/IOSSmoke"):
                        subprocess.run(["xcrun", "devicectl", "device", "process", "signal",
                            "--device", device, "--pid", str(process["processIdentifier"]),
                            "--signal", "SIGKILL", "--timeout", "5"], timeout=10, check=True)
            else:
                subprocess.run(["xcrun", "simctl", "terminate", simulator, BUNDLE], timeout=10, check=True)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            record["cleanup_error"] = str(error)
    record["status"] = ("pass" if record["exit_code"] == 0 else
                        "unsupported" if record["exit_code"] == 77 else "fail")
    Path(str(output) + ".json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"IOS_APPLICATION_RESULT={record['status']} validation=not_enabled")
    return record["exit_code"]


if __name__ == "__main__":
    raise SystemExit(main())

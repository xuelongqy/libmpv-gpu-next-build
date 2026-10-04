"""Offline regression checks; never use real dependency worktrees."""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

here = Path(__file__).resolve().parent
repo = here.parents[1]


def run(args, **kwargs):
    args = [shutil.which(args[0]) or args[0], *args[1:]]
    return subprocess.run(args, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=20, **kwargs)


def shell(script, env=None):
    return run(["bash", "-c", script], env={**os.environ, **(env or {})})


with tempfile.TemporaryDirectory(prefix="vulkan-tools-") as directory:
    temp = Path(directory)
    stable_env = dict(os.environ)
    stable_env.pop("SOURCE_LOCK_FILE", None)
    stable = run(["bash", "-c", f'source "{repo}/scripts/lib/common.sh"; printf "%s" "$MPV_COMMIT"'],
                 env=stable_env)
    assert stable.returncode == 0 and stable.stdout == "c30a27722bc983671e8a11ddacc9480dde29681a"
    valid = (here/"versions.env").read_text()
    for text in (valid.replace("MPV_COMMIT=", "MISSING="),
                 valid.replace("b91f8e58e51e75f68232b720352fdcfd6929e1b3", "bad"),
                 valid.replace("MPV_REPOSITORY=https://github.com/xuelongqy/mpv.git", "MPV_REPOSITORY=")):
        lock = temp/"invalid.env"
        lock.write_text(text)
        check = shell(f'source "{here}/common.sh"', {"SOURCE_LOCK_FILE": str(lock),
                      "MPV_COMMIT": "b91f8e58e51e75f68232b720352fdcfd6929e1b3"})
        assert check.returncode != 0
    missing = shell(f'source "{here}/common.sh"', {"SOURCE_LOCK_FILE": str(temp/"absent.env")})
    assert missing.returncode != 0
    invalid_utf8 = run([sys.executable, "-c",
                        "import sys; sys.stdout.buffer.write(b'bad\\xffoutput')"])
    assert invalid_utf8.returncode == 0 and invalid_utf8.stdout == "bad\ufffdoutput"
    dll_dir = temp/"prefix"/"bin"
    dll_dir.mkdir(parents=True)
    (dll_dir/"libplacebo-372.dll").touch()
    linkage = temp/"linkage.txt"
    dll_check = '''
        placebo_dll=("$PREFIX"/bin/libplacebo-*.dll)
        [[ ${#placebo_dll[@]} == 1 && -f ${placebo_dll[0]} ]] &&
            grep -F "$(basename -- "${placebo_dll[0]}")" "$LINKAGE"
    '''
    linkage.write_text("DLL Name: libplacebo-372.dll\n")
    assert shell(dll_check, {"PREFIX": str(temp/"prefix"), "LINKAGE": str(linkage)}).returncode == 0
    linkage.write_text("DLL Name: libplacebo-371.dll\n")
    assert shell(dll_check, {"PREFIX": str(temp/"prefix"), "LINKAGE": str(linkage)}).returncode != 0
    origin, dest = temp/"origin", temp/"checkout"
    assert run(["git", "init", str(origin)]).returncode == 0
    (origin/"file").write_text("original\n")
    for args in (["add", "file"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                                     "commit", "-m", "fixture"]):
        assert run(["git", "-C", str(origin), *args]).returncode == 0
    commit = run(["git", "-C", str(origin), "rev-parse", "HEAD"]).stdout.strip()
    def checkout(sha):
        return shell(f'source "{here}/common.sh"; ensure_checkout fixture "{origin}" "{sha}" "{dest}"')
    assert checkout(commit).returncode == 0
    assert run(["git", "-C", str(dest), "rev-parse", "HEAD"]).stdout.strip() == commit
    assert checkout("0"*40).returncode != 0
    for kind in ("unstaged", "staged", "untracked"):
        target = dest/("extra" if kind == "untracked" else "file")
        target.write_text("keep me\n")
        if kind == "staged":
            assert run(["git", "-C", str(dest), "add", "file"]).returncode == 0
        before = run(["git", "-C", str(dest), "status", "--porcelain"]).stdout
        assert checkout(commit).returncode != 0
        assert target.read_text() == "keep me\n"
        assert run(["git", "-C", str(dest), "status", "--porcelain"]).stdout == before
        # Restore only the disposable fixture, never a dependency checkout.
        if kind == "untracked":
            target.unlink()
        else:
            run(["git", "-C", str(dest), "restore", "--staged", "--worktree", "file"])
    for name, code in (("pass", 0), ("unsupported", 77), ("fail", 1), ("timeout", 124)):
        command = [sys.executable, "-c", "import time; time.sleep(30)" if code == 124 else f"raise SystemExit({code})"]
        prefix = temp/name
        check = run([sys.executable, str(here/"case.py"), str(prefix),
                     "0.2" if code == 124 else "5", "--", *command])
        assert check.returncode == code, check
        record = json.loads(prefix.with_suffix(".json").read_text())
        assert record["status"] == name
    before = (temp/"pass.json").read_bytes()
    assert run([sys.executable, str(here/"case.py"), str(temp/"pass"), "5", "--",
                sys.executable, "-c", "raise SystemExit(0)"]).returncode != 0
    assert (temp/"pass.json").read_bytes() == before

    argv_script = temp/"argv.sh"
    argv_script.write_text("printf '%s\\n' \"$@\"\n")
    literal_args = ["wasapi/{00000000-0000-0000-0000-000000000000}",
                    "literal[1].mkv", "*.mkv", "two words.mkv"]
    prefix = temp/"argv"
    check = run([sys.executable, str(here/"case.py"), str(prefix), "5", "--",
                 "bash", str(argv_script), *literal_args])
    assert check.returncode == 0, check
    assert prefix.with_suffix(".log").read_text().splitlines() == literal_args

    def check_summary(stage, outcome, smoke_codes=None):
        real_run = subprocess.run
        count = 18 if stage == "matrix" else 1
        codes = smoke_codes if smoke_codes is not None else [0] * count
        key = "comparison_exit" if stage == "matrix" else "pixel_exit"
        timeout = 20 if stage == "matrix" else 120
        argv = [str(here/"check.py"), stage, "--samples", str(temp), "--baseline", str(temp),
                "--media", str(temp/"unused.mkv"), "--audio-device", "fixture"]
        outputs = {
            "pass": (0, "pixels", "details"),
            "fail": (5, "pixels", "details"),
            "timeout": (124, "partial \ufffd", f"Comparison timed out after {timeout} seconds.\nwarning \ufffd"),
            "timeout-empty": (124, "", f"Comparison timed out after {timeout} seconds.\n"),
            "timeout-text": (124, "partial", f"Comparison timed out after {timeout} seconds.\nwarning"),
            "oserror": (2, "", "comparer unavailable"),
            "real-pass": (0, "file: 日.png\npixels \ufffd", "details \ufffd"),
            "real-fail": (5, "file: 日.png\npixels \ufffd", "details \ufffd"),
        }
        completed, compared = [], []

        def smoke(command):
            prefix = Path(command[2])
            # The preceding comparison must be saved before the next smoke starts.
            if completed:
                assert json.loads((prefix.parent/"summary.json").read_text()) == completed
            code = codes[len(completed)]
            prefix.with_suffix(".log").write_text("VALIDATION_ERRORS=0\n")
            completed.append(dict(name=prefix.name, exit_code=code))
            return code

        def compare(command, *, capture_output, text, timeout, **kwargs):
            assert capture_output and text
            assert timeout == (20 if stage == "matrix" else 120)
            selected = outcome if not compared else "pass"
            code, stdout, stderr = outputs[selected]
            completed[-1].update({key: code}, comparison=stdout, comparison_error=stderr)
            if code:
                completed[-1]["exit_code"] = 1
            compared.append(command)
            if selected.startswith("timeout"):
                output, error = {"timeout": (b"partial \xff", b"warning \xff"),
                                 "timeout-empty": (None, None),
                                 "timeout-text": ("partial", "warning")}[selected]
                raise subprocess.TimeoutExpired(command, timeout, output=output, stderr=error)
            if selected == "oserror":
                raise FileNotFoundError("comparer unavailable")
            if selected.startswith("real-"):
                output = "file: 日.png\npixels ".encode("utf-8") + b"\xff"
                child = (f"import sys; sys.stdout.buffer.write({output!r}); "
                         f"sys.stderr.buffer.write(b'details \\xff'); raise SystemExit({code})")
                # Exercise real decoding with a Windows-style default locale.
                with patch("subprocess._text_encoding", return_value="gbk"):
                    return real_run([sys.executable, "-c", child], capture_output=capture_output,
                                    text=text, timeout=timeout, **kwargs)
            return subprocess.CompletedProcess(command, code, stdout, stderr)

        with tempfile.TemporaryDirectory(dir=temp) as work, \
                patch.dict(os.environ, {"WORK_ROOT": work}), patch.object(sys, "argv", argv), \
                patch("subprocess.call", side_effect=smoke), \
                patch("subprocess.run", side_effect=compare), redirect_stdout(io.StringIO()):
            try:
                runpy.run_path(str(here/"check.py"), run_name="__main__")
            except SystemExit as error:
                result = error.code
            else:
                raise AssertionError("missing check exit status")
            summaries = list(Path(work).glob("evidence/*/summary.json"))
            assert len(summaries) == 1
            assert json.loads(summaries[0].read_text()) == completed
            assert len(completed) == count and len(compared) == codes.count(0)
            expected = 1 if any(row["exit_code"] not in (0, 77) for row in completed) else \
                77 if any(row["exit_code"] == 77 for row in completed) else 0
            assert result == expected, (stage, outcome, result, completed)

    for stage in ("matrix", "lifecycle"):
        for outcome in ("pass", "fail", "timeout", "timeout-empty", "timeout-text", "oserror",
                        "real-pass", "real-fail"):
            check_summary(stage, outcome)
        for code in (1, 77):
            check_summary(stage, "pass", [code] * (18 if stage == "matrix" else 1))
    check_summary("matrix", "timeout", [0, 77] + [0] * 16)
    print("COMPARISON_SUMMARIES=PASS")
print("OFFLINE_TOOLS=PASS")

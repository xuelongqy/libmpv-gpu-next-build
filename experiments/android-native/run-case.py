"""Run the existing Android playback, subtitle and dual-Surface checks."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

if not __debug__:
    raise SystemExit("Run without Python optimization; this check relies on assertions.")

if len(sys.argv) != 4:
    raise SystemExit("usage: run-case.py sdr|hdr10|dv SECONDS CASE_NAME")
sample, seconds, name = sys.argv[1:]
assert sample in ("sdr", "hdr10", "dv") and name.replace("-", "").isalnum()
seconds = int(seconds)
assert 1 <= seconds <= 900
renderer = os.environ.get("SMOKE_RENDERER", "mediacodec_embed")
assert renderer in ("mediacodec_embed", "gpu", "gpu-next", "default")
native = renderer == "mediacodec_embed"
output = os.environ.get("SMOKE_OUTPUT", "sdr")
assert output in ("sdr", "pq") and (not native or output == "sdr")
hwdec = os.environ.get("SMOKE_HWDEC", "mediacodec" if native else "no")
assert hwdec in ("no", "mediacodec") and (not native or hwdec == "mediacodec")
volume = int(os.environ.get("SMOKE_VOLUME", "0"))
assert 0 <= volume <= 100
cycles = int(os.environ.get("SMOKE_LIFECYCLE", "0"))
assert 0 <= cycles <= 5 and (not cycles or native)
root = Path(os.environ.get("SMOKE_RESULTS_DIR", Path(__file__).resolve().parent / "../../.work/android-native/results")).resolve()
root.mkdir(parents=True, exist_ok=True)
out = root / name
assert not out.with_suffix(".result.json").exists() and not Path(str(out) + ".stream.log").exists(), "use a fresh case name"
serial = os.environ.get("SMOKE_DEVICE")
assert serial and not serial.startswith("-"), "set SMOKE_DEVICE explicitly"
adb = ["adb", "-P", os.environ.get("SMOKE_ADB_PORT", "5037"), "-s", serial]
package = "is.xyz.mpv.gpunextsmoke"
device = f"/data/user/0/{package}/files"
media_dir = os.environ.get("SMOKE_MEDIA_DIR", "")
assert media_dir and media_dir.replace("-", "").replace("_", "").isalnum(), "set SMOKE_MEDIA_DIR to an app-private folder"
media = f"{device}/{media_dir}/{sample}-av-65s.mkv"
expect_hdmi = os.environ.get("SMOKE_EXPECT_HDMI") == "1"
rotate = os.environ.get("SMOKE_ROTATE") == "1"
if native and sample == "dv" and os.environ.get("SMOKE_NATIVE_DV") != "1":
    raise SystemExit("native DV requires independently confirmed device/display support; set SMOKE_NATIVE_DV=1")
pipe = None
log_capture = None
log_file = None
records = []
result = {"sample": sample, "renderer": renderer, "hwdec": hwdec, "output": output,
          "requested_seconds": seconds, "status": "fail", "device": serial, "hdmi_samples": []}
stamp = None


def run(*args, **kwargs):
    return subprocess.run(adb + list(args), check=True, timeout=12, **kwargs)


try:
    run("shell", "am", "force-stop", package)
    run("shell", "run-as", package, "rm", "-f", f"{device}/acceptance/ipc")
    run("shell", "input", "keyevent", "KEYCODE_WAKEUP")
    run("shell", "input", "keyevent", "KEYCODE_HOME")
    stamp = run("shell", "date", "+%m-%d_%H:%M:%S.000",
                capture_output=True, text=True).stdout.strip().replace("_", " ")
    result["input_sha256"] = run("shell", "run-as", package, "sha256sum", media,
                                capture_output=True, text=True).stdout.split()[0]
    log_file = Path(str(out) + ".stream.log").open("wb")
    log_capture = subprocess.Popen(adb + ["logcat", "-T", stamp,
                                         "-v", "threadtime"], stdout=log_file)
    boot = media
    run("shell", "am", "start", "-n", package + "/is.xyz.mpv.MPVActivity",
        "-a", "android.intent.action.VIEW", "-d", f"file://{boot}",
        "-t", "video/x-matroska", "--es", "file", boot,
        "--es", "mode", "wid" if native else "render-api", "--es", "renderer", renderer,
        "--es", "output", output, "--es", "hwdec", hwdec,
        "--es", "acceptance", "android_native_" + name,
        "--ez", "deterministic", "false")
    deadline = time.monotonic() + 15
    while subprocess.run(adb + ["shell", "run-as", package, "test", "-S",
                                f"{device}/acceptance/ipc"], timeout=5).returncode:
        if time.monotonic() > deadline:
            raise TimeoutError("app IPC did not become available")
        time.sleep(0.1)
    pid = run("shell", "pidof", package, capture_output=True, text=True).stdout.strip()
    assert pid.isdigit(), pid
    result["pid"] = pid
    pipe = subprocess.Popen(adb + ["shell", "-T", "run-as", package, "toybox", "nc",
                                   "-U", f"{device}/acceptance/ipc"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            text=True, bufsize=1)
    messages = queue.Queue()

    def read_messages():
        for line in pipe.stdout:
            messages.put(json.loads(line))
        messages.put(None)

    threading.Thread(target=read_messages, daemon=True).start()
    identity = 0
    pending = []

    def command(*args, optional=False):
        global identity
        identity += 1
        pipe.stdin.write(json.dumps({"command": args, "request_id": identity}) + "\n")
        pipe.stdin.flush()
        deadline = time.monotonic() + 10
        while True:
            message = messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if message is None:
                raise RuntimeError("app IPC closed")
            if message.get("request_id") == identity:
                if message["error"] != "success":
                    if optional:
                        return {"unavailable": message["error"]}
                    raise RuntimeError(message)
                return message.get("data")
            pending.append(message)
            if time.monotonic() > deadline:
                raise TimeoutError("IPC reply deadline expired")

    def event(name):
        deadline = time.monotonic() + 15
        while True:
            for index, message in enumerate(pending):
                if message.get("event") == name:
                    del pending[:index + 1]
                    return message
            message = messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if message is None:
                raise RuntimeError("app IPC closed")
            pending.append(message)
            if time.monotonic() > deadline:
                raise TimeoutError("no " + name)

    result["versions"] = {key: command("get_property", key, optional=True)
                          for key in ("mpv-version", "ffmpeg-version", "libavcodec-version")}
    for key, value in (("audio-channels", "stereo"), ("video-sync", "audio"),
                       ("volume", volume), ("mute", False), ("sid", "no"),
                       ("interpolation", False), ("aid", "auto")):
        command("set_property", key, value)
    deadline = time.monotonic() + 15
    while True:
        actual_hwdec = command("get_property", "hwdec-current", optional=True)
        pts = command("get_property", "time-pos", optional=True)
        if actual_hwdec != hwdec:
            print("STARTUP_STATE=" + json.dumps({"hwdec": actual_hwdec,
                "vo": command("get_property", "current-vo", optional=True),
                "path": command("get_property", "path", optional=True)}), flush=True)
        if actual_hwdec == hwdec and isinstance(pts, (float, int)):
            break
        if time.monotonic() > deadline:
            raise TimeoutError(f"video not ready: hwdec={actual_hwdec}, pts={pts}")
        time.sleep(0.1)
    expected_vo = "mediacodec_embed" if native else "libmpv"
    assert command("get_property", "current-vo") == expected_vo
    command("set_property", "pause", False)
    deadline = time.monotonic() + 10
    while True:
        actual_hwdec = command("get_property", "hwdec-current", optional=True)
        vo = command("get_property", "current-vo", optional=True)
        ao = command("get_property", "current-ao", optional=True)
        audio = command("get_property", "audio-out-params", optional=True)
        assert actual_hwdec == hwdec and vo == expected_vo, (actual_hwdec, vo)
        if ao in ("audiotrack", "opensles") and audio.get("channel-count") == 2:
            break
        if time.monotonic() > deadline:
            raise TimeoutError(f"audio not ready during playback: ao={ao}, audio={audio}")
        time.sleep(0.1)
    result["initial"] = {key: command("get_property", key, optional=True) for key in
                         ("current-vo", "hwdec-current", "video-params", "video-out-params",
                          "audio-params", "audio-out-params", "current-ao", "audio-device",
                          "volume", "mute", "duration")}
    assert result["initial"]["current-ao"] in ("audiotrack", "opensles")
    assert result["initial"]["audio-out-params"]["channel-count"] == 2
    print("NATIVE_READY=" + sample + " " + json.dumps(result["initial"]), flush=True)
    print("PLAYBACK_STARTED=" + sample, flush=True)
    begin = time.monotonic()
    while time.monotonic() - begin < seconds:
        values = {key: command("get_property", key, optional=True) for key in
                  ("time-pos", "audio-pts", "avsync", "hwdec-current", "current-vo",
                   "pause", "eof-reached", "frame-drop-count", "decoder-frame-drop-count")}
        values["elapsed"] = round(time.monotonic() - begin, 3)
        assert values["hwdec-current"] == hwdec, values
        assert values["current-vo"] == expected_vo, values
        assert not values["pause"] and not values["eof-reached"], values
        records.append(values)
        print(json.dumps(values), flush=True)
        if len(records) == 4:
            result["render_target"] = command("get_property", "video-target-params", optional=True)
            for suffix, args in (("surfaceflinger.txt", ("shell", "dumpsys", "SurfaceFlinger")),
                                 ("audio.txt", ("shell", "dumpsys", "media.audio_flinger")),
                                 ("libraries.txt", ("shell", "run-as", package, "cat", f"/proc/{pid}/maps"))):
                Path(str(out) + "." + suffix).write_text(run(*args, capture_output=True, text=True).stdout)
            # Reuse the live capture instead of opening another log reader.
            Path(str(out) + ".startup.log").write_bytes(Path(str(out) + ".stream.log").read_bytes())
        time.sleep(1)
    assert len(records) >= (2 if seconds > 5 else 1)
    assert records[-1]["time-pos"] - records[0]["time-pos"] >= seconds - 5
    audio_samples = [row for row in records if isinstance(row["audio-pts"], (int, float))]
    assert audio_samples and audio_samples[-1]["audio-pts"] - audio_samples[0]["audio-pts"] >= seconds - 5
    if not native:
        log = Path(str(out) + ".stream.log").read_text(errors="replace")
        assert "ACCEPTANCE_FBO=PASS" in log and "ACCEPTANCE_FBO=FAIL" not in log
        assert "Render API: render failed" not in log and "create failed" not in log
        ppm = run("exec-out", "run-as", package, "cat",
                  f"{device}/acceptance/android_native_{name}.ppm", capture_output=True).stdout
        magic, dimensions, maximum, pixels = ppm.split(b"\n", 3)
        width, height = map(int, dimensions.split())
        assert magic == b"P6" and maximum == b"255" and len(pixels) == width * height * 3
        assert max(pixels) - min(pixels) > 8, "target readback has no video content"
        Path(str(out) + ".target.ppm").write_bytes(ppm)
        result["target_readback"] = dict(width=width, height=height,
                                        minimum=min(pixels), maximum=max(pixels))

    def resume():
        command("set_property", "pause", False)
        video_before = command("get_property", "time-pos")
        audio_before = command("get_property", "audio-pts", optional=True)
        deadline = time.monotonic() + 15
        while True:
            video_now = command("get_property", "time-pos", optional=True)
            audio_now = command("get_property", "audio-pts", optional=True)
            if (isinstance(video_now, (int, float)) and isinstance(audio_now, (int, float))
                    and video_now > video_before + 0.25
                    and (not isinstance(audio_before, (int, float)) or audio_now > audio_before + 0.25)):
                assert command("get_property", "hwdec-current") == hwdec
                assert command("get_property", "current-vo") == expected_vo
                assert not command("get_property", "pause")
                return video_now, audio_now
            if time.monotonic() > deadline:
                raise TimeoutError("video/audio did not resume")
            time.sleep(0.05)

    def activity(action):
        launched = run("shell", "am", "start", "--activity-single-top", "-n",
            package + "/is.xyz.mpv.MPVActivity", "-a", "android.intent.action.VIEW",
            "-d", "file://" + media, "-t", "video/x-matroska",
            "--es", "acceptance-action", action,
            capture_output=True, text=True)
        assert "Error" not in launched.stdout + launched.stderr, launched
        if action in ("surface-hide", "surface-show", "overlay-hide", "overlay-show"):
            deadline = time.monotonic() + 15
            while True:
                state = {key: command("get_property", key, optional=True)
                         for key in ("vid", "current-vo", "hwdec-current")}
                if action.endswith("hide"):
                    ready = (state["vid"] is False and
                             state["current-vo"] == {"unavailable": "property unavailable"})
                else:
                    ready = state["current-vo"] == expected_vo and state["hwdec-current"] == hwdec
                if ready:
                    result.setdefault("surface_checks", []).append(dict(action=action, state=state))
                    break
                if time.monotonic() > deadline:
                    raise TimeoutError(f"{action} did not complete: {state}")
                time.sleep(.05)
        elif action == "foreground":
            deadline = time.monotonic() + 15
            while True:
                state = run("shell", "dumpsys", "activity", "activities",
                            capture_output=True, text=True).stdout
                resumed = [line.strip() for line in state.splitlines()
                           if "mResumedActivity:" in line or "topResumedActivity=" in line]
                if any(package + "/is.xyz.mpv.MPVActivity" in line for line in resumed):
                    result.setdefault("foreground_checks", []).append(resumed)
                    break
                if time.monotonic() > deadline:
                    raise TimeoutError("activity did not return to foreground")
                time.sleep(.05)

    def wait_log(marker, count):
        deadline = time.monotonic() + 15
        while Path(str(out) + ".stream.log").read_text(errors="replace").count(marker) <= count:
            if time.monotonic() > deadline:
                raise TimeoutError("no new " + marker)
            time.sleep(0.05)

    subtitle = os.environ.get("SMOKE_SUBTITLE")
    result["subtitle_checks"] = []
    if subtitle:
        assert native and subtitle in ("srt", "ass", "sup", "mks")
        from PIL import Image
        import numpy as np
        import io
        command("set_property", "osd-level", 0)
        command("set_property", "sub-files", [f"{device}/native-subtitles.{subtitle}"])
        command("sub-add", f"{device}/native-subtitles.{subtitle}", "select")
        selected = command("get_property", "sid")

        def seek(pts):
            command("set_property", "pause", True)
            pending.clear()
            command("seek", pts, "absolute+exact")
            event("seek")
            event("playback-restart")
            actual = command("get_property", "time-pos")
            assert abs(actual - pts) <= .05, actual

        def snapshot(label, visible):
            deadline = time.monotonic() + 8
            attempt = 0
            while True:
                suffix = f"{name}-{label}-{attempt}"
                run("shell", "am", "start", "--activity-single-top", "-n",
                    package + "/is.xyz.mpv.MPVActivity", "-a", "android.intent.action.VIEW",
                    "-d", "file://" + media, "-t", "video/x-matroska",
                    "--es", "acceptance-action", "capture-overlay", "--es", "acceptance-name", suffix,
                    capture_output=True, text=True)
                path = f"{device}/acceptance/{suffix}"
                while subprocess.run(adb + ["shell", "run-as", package, "test", "-f", path + ".status"],
                                     timeout=5).returncode:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("no PixelCopy result for " + suffix)
                    time.sleep(.05)
                status = run("shell", "run-as", package, "cat", path + ".status",
                             capture_output=True, text=True).stdout.strip()
                assert status == "0", (suffix, status)
                png = run("exec-out", "run-as", package, "cat", path + ".png", capture_output=True).stdout
                local = Path(str(out) + f"-{label}-{attempt}.png")
                local.write_bytes(png)
                pixels = np.asarray(Image.open(io.BytesIO(png)).convert("RGBA"))
                alpha = pixels[:, :, 3]
                actual = bool(np.any(alpha))
                if actual == visible:
                    result["subtitle_checks"].append(dict(label=label, visible=visible,
                        pts=command("get_property", "time-pos", optional=True),
                        image=local.name, width=pixels.shape[1], height=pixels.shape[0]))
                    if visible:
                        assert np.count_nonzero(alpha == 0) > alpha.size * .75, suffix
                    return result["subtitle_checks"][-1]
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"subtitle visibility {actual}, expected {visible}: {suffix}")
                attempt += 1

        count = int(os.environ.get("SMOKE_SUBTITLE_CYCLES", "1"))
        assert 1 <= count <= 10
        for index in range(count):
            seek(.75)
            snapshot(f"visible-{index}", True)
            if expect_hdmi:
                hdr = run("shell", "cat", "/sys/class/amhdmitx/amhdmitx0/hdmi_hdr_status",
                          capture_output=True, text=True).stdout.strip()
                result["hdmi_samples"].append(dict(cycle=index+1, hdr=hdr,
                                                  subtitle_visible=True, pts=.75))
                if sample.startswith("dv"):
                    assert "dolbyvision" in hdr.lower().replace(" ", ""), hdr
                elif sample == "hdr10":
                    assert "HDR10" in hdr, hdr
            command("set_property", "sub-visibility", False)
            snapshot(f"hidden-{index}", False)
            command("set_property", "sub-visibility", True)
            snapshot(f"restored-{index}", True)
            command("set_property", "sub-delay", 2)
            snapshot(f"delayed-{index}", False)
            command("set_property", "sub-delay", 0)
            command("set_property", "sid", "no")
            snapshot(f"no-track-{index}", False)
            command("set_property", "sid", selected)
            snapshot(f"track-restored-{index}", True)
            seek(2)
            snapshot(f"gap-{index}", False)
            print(f"SUBTITLE_CONTROLS={index+1}/{count} PASS", flush=True)
        command("set_property", "idle", "yes")
        command("stop")
        event("end-file")
        event("idle")
        snapshot("stop", False)
        pending.clear()
        command("loadfile", media)
        event("file-loaded")
        event("playback-restart")
        assert command("get_property", "current-vo") == expected_vo
        assert command("get_property", "hwdec-current") == hwdec
        resume()
        Path(str(out) + ".subtitle-surfaceflinger.txt").write_text(run(
            "shell", "dumpsys", "SurfaceFlinger", capture_output=True, text=True).stdout)

    result["lifecycle"] = []
    for index in range(cycles):
        command("set_property", "idle", "yes")
        command("set_property", "pause", True)
        pending.clear()
        command("seek", 5 + index, "absolute+exact")
        event("seek")
        event("playback-restart")
        seek_pts = command("get_property", "time-pos")
        assert abs(seek_pts - (5 + index)) <= 0.05, seek_pts
        resume()
        activity("surface-hide")
        activity("surface-show")
        resume()
        if subtitle:
            seek(.75)
            snapshot(f"surface-resume-{index}", True)
            activity("overlay-hide")
            activity("overlay-show")
            resume()
            seek(.75)
            snapshot(f"overlay-resume-{index}", True)
            if rotate:
                before = Path(str(out) + ".stream.log").read_text(errors="replace").count("ACCEPTANCE_SURFACE_SIZE=")
                activity("rotate")
                wait_log("ACCEPTANCE_SURFACE_SIZE=", before)
                resume()
                seek(.75)
                rotated = snapshot(f"rotation-{index}", True)
                assert (rotated["width"] > rotated["height"]) != (index % 2 == 0), rotated
            resume()
        before = Path(str(out) + ".stream.log").read_text(errors="replace").count("ACCEPTANCE_ACTIVITY_STOPPED")
        activity("background")
        deadline = time.monotonic() + 15
        while True:
            state = run("shell", "dumpsys", "activity", "activities",
                        capture_output=True, text=True).stdout
            resumed = [line.strip() for line in state.splitlines()
                       if "mResumedActivity:" in line or "topResumedActivity=" in line]
            if resumed and all(package not in line for line in resumed) and command("get_property", "pause"):
                result.setdefault("background_checks", []).append(dict(cycle=index+1,
                    resumed=resumed, on_stop=Path(str(out) + ".stream.log").read_text(
                        errors="replace").count("ACCEPTANCE_ACTIVITY_STOPPED") > before))
                break
            if time.monotonic() > deadline:
                raise TimeoutError("activity did not enter paused background state")
            time.sleep(.05)
        activity("foreground")
        resume()
        if subtitle:
            seek(.75)
            snapshot(f"foreground-{index}", True)
            resume()
        pending.clear()
        command("stop")
        event("end-file")
        event("idle")
        assert command("get_property", "idle-active")
        clips = ("sdr", "hdr10", "dv") if os.environ.get("SMOKE_NATIVE_DV") == "1" else ("sdr", "hdr10")
        for clip in ((sample,) if os.environ.get("SMOKE_LIFECYCLE_SINGLE") == "1" else clips):
            pending.clear()
            command("loadfile", f"{device}/{media_dir}/{clip}-av-65s.mkv")
            event("start-file")
            event("file-loaded")
            event("playback-restart")
            resume()
            if subtitle:
                seek(.75)
                snapshot(f"reload-{index}-{clip}", True)
                resume()
            result["lifecycle"].append({"cycle": index + 1, "sample": clip})
        print("NATIVE_LIFECYCLE=" + str(index + 1) + "/" + str(cycles) + " PASS", flush=True)
    result.update(status="pass", elapsed_seconds=round(time.monotonic() - begin, 3))
except Exception as error:
    result["error"] = repr(error)
    raise
finally:
    result["samples"] = records
    if pipe is not None:
        try:
            pipe.stdin.write('{"command":["quit"]}\n')
            pipe.stdin.flush()
            pipe.communicate(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            pipe.kill()
            pipe.wait(timeout=3)
    try:
        try:
            run("shell", "am", "force-stop", package)
        finally:
            if log_capture is not None:
                log_capture.terminate()
                log_capture.wait(timeout=3)
            if log_file is not None:
                Path(str(out) + ".device.log").write_bytes(Path(str(out) + ".stream.log").read_bytes())
    except Exception as error:
        result["status"] = "fail"
        result["cleanup_error"] = repr(error)
        raise
    finally:
        if log_file is not None:
            log_file.close()
        Path(str(out) + ".result.json").write_text(json.dumps(result, indent=2) + "\n")

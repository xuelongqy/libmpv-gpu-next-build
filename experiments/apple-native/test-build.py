"""Offline checks for accepted patched sources and local-edit protection."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PatchedSource(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="native-source-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "ffmpeg"
        self.source.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Offline fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgSign", "false")
        (self.source / "decoder.c").write_text("base\n")
        (self.source / "version.h").write_text("unchanged\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        base = self.git("rev-parse", "HEAD").strip()
        (self.source / "decoder.c").write_text("native\n")
        self.git("commit", "-qam", "native")
        tree = self.git("rev-parse", "HEAD^{tree}").strip()
        patch = self.git("format-patch", "--stdout", "--full-index", "--no-signature", "-1").encode()
        self.git("checkout", "--detach", "-q", base)
        self.entry = self.root / "prepare-ffmpeg.sh"
        shutil.copyfile(Path(__file__).with_name(self.entry.name), self.entry)
        (self.root / "native.patch").write_bytes(patch)
        (self.root / "versions.env").write_text(
            f"FFMPEG_COMMIT={base}\nFFMPEG_PATCH=native.patch\n"
            f"FFMPEG_PATCH_SHA256={hashlib.sha256(patch).hexdigest()}\n"
            f"FFMPEG_PATCHED_TREE={tree}\n")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args], text=True)

    def run_entry(self, *args):
        return subprocess.run(["bash", str(self.entry), *args, str(self.source)],
                              capture_output=True, text=True)

    def prepare(self):
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)

    def reject_check(self):
        contents = {name: (self.source / name).read_bytes()
                    for name in ("decoder.c", "version.h")}
        index = (self.source / ".git/index").read_bytes()
        result = self.run_entry("--check")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(index, (self.source / ".git/index").read_bytes())
        self.assertEqual(contents, {name: (self.source / name).read_bytes() for name in contents})

    def test_apply_then_read_only_check(self):
        self.prepare()
        index = (self.source / ".git/index").read_bytes()
        result = self.run_entry("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(index, (self.source / ".git/index").read_bytes())
        self.assertNotEqual(self.run_entry().returncode, 0)

    def test_unpatched_source_is_not_accepted_as_patched(self):
        self.reject_check()

    def test_extra_edit(self):
        self.prepare()
        (self.source / "version.h").write_text("local edit\n")
        self.reject_check()

    def test_hidden_edit(self):
        self.prepare()
        self.git("update-index", "--assume-unchanged", "version.h")
        (self.source / "version.h").write_text("hidden edit\n")
        self.reject_check()

    def test_staged_patch(self):
        self.prepare()
        self.git("add", "decoder.c")
        self.reject_check()

    def test_untracked_edit(self):
        self.prepare()
        (self.source / "local.txt").write_text("keep me\n")
        self.reject_check()
        self.assertEqual((self.source / "local.txt").read_text(), "keep me\n")

    def test_intent_to_add(self):
        self.prepare()
        (self.source / "local.txt").write_text("keep me\n")
        self.git("add", "-N", "local.txt")
        self.reject_check()
        self.assertEqual((self.source / "local.txt").read_text(), "keep me\n")

    def test_ios_default_and_native_arguments(self):
        ios_dir = Path(__file__).parent.parent / "vulkan/ios"
        entry = self.root / "build-libs.sh"
        shutil.copyfile(ios_dir / entry.name, entry)
        shutil.copyfile(ios_dir / "cross.ini.in", self.root / "cross.ini.in")
        work = self.root / "ios"
        (work / "prefix/lib/pkgconfig").mkdir(parents=True)
        sdk = self.root / "sdk"
        (sdk / "usr/include").mkdir(parents=True)
        (sdk / "usr/include/zlib.h").write_text('#define ZLIB_VERSION "1.3.1"\n')
        sources = self.root / "sources"
        sources.mkdir()
        for name in ("mpv", "libplacebo"):
            (sources / name).symlink_to(self.source, target_is_directory=True)
        for name in ("vulkan", "libshaderc", "libass", "libfreetype", "libfribidi",
                     "libharfbuzz", "libunibreak"):
            dep = work / "deps" / name
            (dep / "include").mkdir(parents=True)
            (dep / "lib/ios/thin/arm64/lib").mkdir(parents=True)
            pc = dep / "pkgconfig-example/ios/arm64"
            pc.mkdir(parents=True)
            (pc / "fixture.pc").write_text("prefix=/path/to/workdir\n")
        molten = work / "deps/vulkan/lib/MoltenVK.xcframework/ios-arm64"
        molten.mkdir(parents=True)
        (molten / "libMoltenVK.a").write_bytes(b"fixture")
        (self.root / "common.sh").write_text(
            'ios_dir=$TEST_DIR\n'
            'ios_work=$TEST_WORK; prefix=$ios_work/prefix; sdk=$TEST_SDK\n'
            'sdk_name=iphoneos; platform=device; kit_platform=ios; molten=ios-arm64\n'
            'target=arm64-apple-ios15.0; source_root=$TEST_SOURCES; jobs=1\n'
            'MPV_COMMIT=$TEST_COMMIT; LIBPLACEBO_COMMIT=$TEST_COMMIT\n'
            'setup_meson() { printf "%s\\0" "$@" >> "$TEST_ARGUMENTS"; }\n')
        tools = self.root / "bin"
        tools.mkdir()
        for name, body in {
            "xcrun": 'case "$*" in *--show-sdk-version) echo 17.0;; *) echo /usr/bin/true;; esac',
            "meson": "exit 0", "pkg-config": "exit 0",
        }.items():
            tool = tools / name
            tool.write_text("#!/bin/sh\n" + body + "\n")
            tool.chmod(0o755)
        record = self.root / "arguments.bin"
        env = dict(os.environ, TEST_DIR=str(self.root), TEST_WORK=str(work), TEST_SDK=str(sdk),
                   TEST_SOURCES=str(sources), TEST_COMMIT=self.git("rev-parse", "HEAD").strip(),
                   TEST_ARGUMENTS=str(record), PATH=f"{tools}:{os.environ['PATH']}")
        shell = "/bin/bash" if Path("/bin/bash").exists() else "bash"
        arguments = []
        for options in ([], ["--apple-native"]):
            record.write_bytes(b"")
            result = subprocess.run([shell, str(entry), *options], env=env,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments.append(record.read_bytes().decode().split("\0")[:-1])
        self.assertNotIn("-Dapple-native=enabled", arguments[0])
        self.assertEqual(arguments[1], arguments[0] + ["-Dapple-native=enabled"])


if __name__ == "__main__":
    unittest.main()

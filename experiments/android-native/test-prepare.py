"""Small offline checks for the locked Android candidate; no SDK or device."""
import hashlib
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


class SourceProtection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="android-native-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / "work"
        self.values = {}
        self.origin = self.root / "origin"
        self.origin.mkdir()
        self.git(self.origin, "init", "-q")
        self.git(self.origin, "config", "user.name", "Offline fixture")
        self.git(self.origin, "config", "user.email", "fixture@example.invalid")
        self.git(self.origin, "config", "commit.gpgSign", "false")
        (self.origin / ".gitignore").write_text("buildscripts/\n")
        (self.origin / "source.c").write_text("base\n")
        self.git(self.origin, "add", ".")
        self.git(self.origin, "commit", "-qm", "base")
        base = self.git(self.origin, "rev-parse", "HEAD").strip()
        (self.origin / "source.c").write_text("native\n")
        patch = self.git(self.origin, "diff", "--full-index").encode()
        with tempfile.TemporaryDirectory() as index_dir:
            env = dict(os.environ, GIT_INDEX_FILE=index_dir + "/index")
            self.git(self.origin, "read-tree", "HEAD", env=env)
            self.git(self.origin, "add", "-u", env=env)
            tree = self.git(self.origin, "write-tree", env=env).strip()
        (self.origin / "source.c").write_text("base\n")
        (self.root / "native.patch").write_bytes(patch)
        for prefix in ("MPV", "FFMPEG", "MPV_ANDROID"):
            self.values.update({prefix + "_REPOSITORY": str(self.origin),
                prefix + "_COMMIT": base, prefix + "_PATCH": "native.patch",
                prefix + "_PATCH_SHA256": hashlib.sha256(patch).hexdigest(),
                prefix + "_PATCHED_TREE": tree})
        self.values.update(LIBPLACEBO_REPOSITORY=str(self.origin), LIBPLACEBO_COMMIT=base,
            DEPENDENCIES_LOCK="dependencies.tsv",
            DEPENDENCIES_LOCK_SHA256=hashlib.sha256(b"# empty offline fixture\n").hexdigest())
        (self.root / "dependencies.tsv").write_text("# empty offline fixture\n")
        self.entry = Path(__file__).with_name("prepare.sh")
        self.write_lock()

    def git(self, path, *args, env=None):
        return subprocess.check_output(["git", "-C", str(path), *args], text=True, env=env)

    def write_lock(self):
        (self.root / "versions.env").write_text("".join(f"{k}={v}\n" for k, v in self.values.items()))

    def run_entry(self, *args):
        return subprocess.run(["bash", str(self.entry), *args], capture_output=True, text=True,
            env=dict(os.environ, SOURCE_LOCK_FILE=str(self.root / "versions.env"),
                     WORK_ROOT=str(self.work)), timeout=30)

    def prepared(self):
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.work / "mpv-android/buildscripts/deps/mpv"

    def test_apply_and_check_keep_index(self):
        source = self.prepared()
        index = (source / ".git/index").read_bytes()
        self.assertEqual(self.run_entry("--check").returncode, 0)
        self.assertEqual(self.run_entry().returncode, 0)
        self.assertEqual(index, (source / ".git/index").read_bytes())
        self.assertEqual((source / "source.c").read_text(), "native\n")
        generated = source.parent / "ffmpeg/_build_armv7l/config.h"
        generated.parent.mkdir()
        generated.write_text("generated\n")
        self.assertEqual(self.run_entry("--check").returncode, 0)

    def test_missing_field_does_not_inherit_environment(self):
        del self.values["MPV_PATCHED_TREE"]
        self.write_lock()
        with unittest.mock.patch.dict(os.environ, MPV_PATCHED_TREE="a" * 40):
            self.assertNotEqual(self.run_entry().returncode, 0)
        self.assertFalse((self.work / "mpv-android").exists())

    def test_invalid_sha(self):
        self.values["FFMPEG_COMMIT"] = "short"
        self.write_lock()
        self.assertNotEqual(self.run_entry().returncode, 0)
        self.assertFalse((self.work / "mpv-android").exists())

    def test_wrong_patch_hash(self):
        self.values["MPV_PATCH_SHA256"] = "0" * 64
        self.write_lock()
        self.assertNotEqual(self.run_entry().returncode, 0)
        self.assertFalse((self.work / "mpv-android").exists())

    def test_wrong_tree_does_not_apply_patch(self):
        self.values["MPV_ANDROID_PATCHED_TREE"] = "0" * 40
        self.write_lock()
        self.assertNotEqual(self.run_entry().returncode, 0)
        self.assertEqual((self.work / "mpv-android/source.c").read_text(), "base\n")

    def test_modified_and_hidden_sources_are_preserved(self):
        for hidden in (False, True):
            source = self.prepared()
            if hidden:
                self.git(source, "update-index", "--assume-unchanged", "source.c")
            (source / "source.c").write_text("local edit\n")
            index = (source / ".git/index").read_bytes()
            self.assertNotEqual(self.run_entry().returncode, 0)
            self.assertEqual((source / "source.c").read_text(), "local edit\n")
            self.assertEqual(index, (source / ".git/index").read_bytes())
            (source / "source.c").write_text("native\n")
            self.git(source, "update-index", "--no-assume-unchanged", "source.c")

    def test_staged_and_untracked_sources_are_preserved(self):
        source = self.prepared()
        local = source / "local.c"
        local.write_text("preserve me\n")
        self.assertNotEqual(self.run_entry().returncode, 0)
        self.git(source, "add", "local.c")
        index = (source / ".git/index").read_bytes()
        self.assertNotEqual(self.run_entry().returncode, 0)
        self.assertEqual(local.read_text(), "preserve me\n")
        self.assertEqual(index, (source / ".git/index").read_bytes())

    def test_wrong_source_head(self):
        source = self.prepared()
        actual = self.git(source, "rev-parse", "HEAD").strip()
        self.values["MPV_COMMIT"] = "0" * 40
        self.write_lock()
        self.assertNotEqual(self.run_entry().returncode, 0)
        self.assertEqual(self.git(source, "rev-parse", "HEAD").strip(), actual)

    def test_archive_local_edits_are_preserved(self):
        archive = self.root / "release"
        archive.mkdir()
        (archive / "source.c").write_text("release\n")
        self.git(archive, "init", "-q")
        self.git(archive, "add", "source.c")
        tree = self.git(archive, "write-tree").strip()
        cache = self.work / "downloads/release.archive"
        cache.parent.mkdir(parents=True)
        with tarfile.open(cache, "w") as stream:
            stream.add(archive / "source.c", arcname="release/source.c")
        digest = hashlib.sha256(cache.read_bytes()).hexdigest()
        rows = f"release tar https://example.invalid/source.tar 1 {digest} {tree}\n"
        (self.root / "dependencies.tsv").write_text(rows)
        self.values["DEPENDENCIES_LOCK_SHA256"] = hashlib.sha256(rows.encode()).hexdigest()
        self.write_lock()
        self.prepared()
        source = self.work / "mpv-android/buildscripts/deps/release"
        self.assertEqual(self.run_entry("--check").returncode, 0)
        self.git(source, "update-index", "--assume-unchanged", "source.c")
        (source / "source.c").write_text("local release edit\n")
        self.assertNotEqual(self.run_entry().returncode, 0)
        self.assertEqual((source / "source.c").read_text(), "local release edit\n")

    def test_submodule_local_edits_are_preserved(self):
        self.git(self.origin, "-c", "protocol.file.allow=always", "submodule", "add", "-q",
                 str(self.origin), "child")
        self.git(self.origin, "commit", "-qam", "submodule fixture")
        self.values["LIBPLACEBO_COMMIT"] = self.git(self.origin, "rev-parse", "HEAD").strip()
        self.write_lock()
        with unittest.mock.patch.dict(os.environ, GIT_CONFIG_COUNT="1",
                GIT_CONFIG_KEY_0="protocol.file.allow", GIT_CONFIG_VALUE_0="always"):
            self.prepared()
            child = self.work / "mpv-android/buildscripts/deps/libplacebo/child"
            (child / "source.c").write_text("local submodule edit\n")
            self.assertNotEqual(self.run_entry().returncode, 0)
            self.assertEqual((child / "source.c").read_text(), "local submodule edit\n")


if __name__ == "__main__":
    from unittest import mock
    unittest.main()

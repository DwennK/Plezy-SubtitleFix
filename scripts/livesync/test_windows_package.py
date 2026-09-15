#!/usr/bin/env python3
"""Packaging safety tests with synthetic PE bytes, never runtime PCM proof."""

import base64
import json
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from stage_windows_package import COMPATIBILITY_PATCH, INPUTS, PATCH, ROOT, stage, verify_run
from prepare_native import digest


class WindowsPackageTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.destination = self.root / "LiveSyncMPV"
        self.archive = self.root / "mpv.zip"

    def archive_with(self, machine=0x8664, properties=True, extra=None):
        image = bytearray(128)
        image[:2] = b"MZ"
        struct.pack_into("<I", image, 0x3C, 64)
        image[64:68] = b"PE\0\0"
        struct.pack_into("<H", image, 68, machine)
        if properties:
            image += b"livesync-enabled\0livesync-pcm\0"
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.writestr("libmpv-2.dll", image)
            for name in ("libmpv.dll.a", "include/mpv/client.h", "include/mpv/render.h"):
                bundle.writestr(name, "fixture")
            if extra:
                bundle.writestr(extra, "invalid")

    def test_stage_preserves_build_identity_and_records_content_hashes(self):
        self.archive_with()
        record = stage(self.archive, self.destination, {"buildRun": 123})
        self.assertEqual(record["buildRun"], 123)
        self.assertEqual(record["architecture"], "x86_64")
        self.assertEqual(len(record["dllSha256"]), 64)
        self.assertEqual(json.loads((self.destination / "livesync-provenance.json").read_text()), record)
        self.assertEqual(stage(self.archive, self.destination, {"buildRun": 124})["buildRun"], 124)

    def test_failure_leaves_previous_package_unchanged(self):
        self.archive_with()
        stage(self.archive, self.destination, {"buildRun": 123})
        before = (self.destination / "libmpv-2.dll").read_bytes()
        for machine, properties in ((0xAA64, True), (0x8664, False)):
            self.archive_with(machine=machine, properties=properties)
            with self.assertRaises(ValueError):
                stage(self.archive, self.destination, {"buildRun": 999})
            self.assertEqual((self.destination / "libmpv-2.dll").read_bytes(), before)
        self.assertEqual(list(self.root.glob(".livesync-mpv-*")), [])

    def test_rejects_unsafe_archive_paths(self):
        for name in ("../escape", "/absolute", "C:/drive", "folder\\escape", "LIBMPV-2.DLL"):
            with self.subTest(name=name):
                self.archive_with(extra=name)
                with self.assertRaises(ValueError):
                    stage(self.archive, self.destination, {})
                self.assertFalse(self.destination.exists())

    def test_preserves_unrelated_directory(self):
        self.archive_with()
        self.destination.mkdir()
        (self.destination / "personal.txt").write_text("keep")
        with self.assertRaises(ValueError):
            stage(self.archive, self.destination, {})
        self.assertEqual((self.destination / "personal.txt").read_text(), "keep")

    def test_rejects_other_run_and_changed_native_inputs(self):
        info = {"conclusion": "success", "status": "completed", "event": "workflow_dispatch",
                "path": ".github/workflows/livesync-mpv-build.yml", "head_sha": "a" * 40,
                "head_repository": {"full_name": "DwennK/Plezy-SubtitleFix"}}
        contents = [{"content": base64.b64encode((ROOT / name).read_bytes()).decode()} for name in INPUTS]
        artifact = {"name": "livesync-mpv-windows-x64-" + "a" * 40, "expired": False}
        with patch("stage_windows_package.api", side_effect=[info, *contents, {"artifacts": [artifact]}]):
            self.assertEqual(verify_run("DwennK/Plezy-SubtitleFix", 123)[1], artifact)
        with patch("stage_windows_package.api", return_value=dict(info, event="pull_request")):
            with self.assertRaises(ValueError):
                verify_run("DwennK/Plezy-SubtitleFix", 123)
        with patch("stage_windows_package.api", side_effect=[info, {"content": "YmFk"}]):
            with self.assertRaisesRegex(ValueError, "inputs changed"):
                verify_run("DwennK/Plezy-SubtitleFix", 123)

    def test_hashed_inputs_survive_windows_checkout_conversion(self):
        repository = self.root / "checkout-filter-test"
        repository.mkdir()
        subprocess.run(["git", "init", "-q", str(repository)], check=True)
        subprocess.run(["git", "-C", str(repository), "config", "core.autocrlf", "true"], check=True)
        shutil.copyfile(ROOT / ".gitattributes", repository / ".gitattributes")
        for name in INPUTS:
            target = repository / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        subprocess.run(["git", "-C", str(repository), "add", ".gitattributes", *INPUTS], check=True,
                       capture_output=True)
        output = self.root / "filtered"
        output.mkdir()
        subprocess.run(["git", "-C", str(repository), "checkout-index", "--all", "--prefix=" + str(output) + "/"],
                       check=True, capture_output=True)
        for name in INPUTS:
            self.assertEqual((output / name).read_bytes(), (ROOT / name).read_bytes(), name)
    @unittest.skipUnless(shutil.which("cmake"), "CMake not installed")
    def test_cmake_checks_staged_bytes_and_native_revision(self):
        project = self.root / "project"
        cmake_dir = project / "windows/cmake"
        cmake_dir.mkdir(parents=True)
        shutil.copyfile(ROOT / "windows/cmake/livesync_mpv.cmake", cmake_dir / "livesync_mpv.cmake")
        patch_path = project / PATCH
        patch_path.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / PATCH, patch_path)
        shutil.copyfile(ROOT / COMPATIBILITY_PATCH, project / COMPATIBILITY_PATCH)
        (project / "CMakeLists.txt").write_text(
            'cmake_minimum_required(VERSION 3.19)\nproject(packaging_test NONE)\n'
            'set(MPV_LOCK "{\\"commit\\":\\"expected\\"}")\n'
            'include(windows/cmake/livesync_mpv.cmake)\n')
        command = ["cmake", "-S", str(project), "-B", str(self.root / "cmake-build")]
        missing = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("Stage the patched", missing.stderr)
        self.archive_with()
        staged = project / "windows/LiveSyncMPV"
        provenance = {"nativeRevision": "expected", "liveSyncPatchSha256": digest(ROOT / PATCH),
                      "windowsCompatibilityPatchSha256": digest(ROOT / COMPATIBILITY_PATCH)}
        stage(self.archive, staged, provenance)
        good = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
        (staged / "libmpv-2.dll").write_bytes(b"corrupted")
        bad = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("stale or corrupt", bad.stderr)
        stage(self.archive, staged, dict(provenance, nativeRevision="wrong"))
        stale = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(stale.returncode, 0)
        self.assertIn("stale or corrupt", stale.stderr)
if __name__ == "__main__":
    unittest.main()

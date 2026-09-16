import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import upstream_sync as sync


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="livesync-upstream-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        sync.git(self.root, "init", "-b", "main")
        sync.git(self.root, "config", "user.name", "Integration fixture")
        sync.git(self.root, "config", "user.email", "fixture@example.invalid")
        self.base = self.commit("shared.txt", "base\n")
        sync.git(self.root, "checkout", "-b", "official")
        self.upstream = self.commit("upstream.txt", "new upstream\n")
        sync.git(self.root, "checkout", "-b", sync.MAINTAINED, self.base)
        self.maintained = self.commit("patch.txt", "LiveSync patch\n")

    def commit(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        sync.git(self.root, "add", name)
        sync.git(self.root, "commit", "-m", "fixture: " + name)
        return sync.git(self.root, "rev-parse", "HEAD")

    def test_merge_preserves_both_histories_without_changing_maintained_or_mirror(self):
        candidate = sync.merge_candidate(self.root, self.maintained, self.upstream)
        self.assertTrue(sync.ancestor(self.root, self.maintained, candidate))
        self.assertTrue(sync.ancestor(self.root, self.upstream, candidate))
        self.assertEqual((self.root / "patch.txt").read_text(), "LiveSync patch\n")
        self.assertEqual((self.root / "upstream.txt").read_text(), "new upstream\n")
        self.assertEqual(sync.git(self.root, "rev-parse", sync.MAINTAINED), self.maintained)
        self.assertEqual(sync.git(self.root, "rev-parse", "main"), self.base)

    def test_existing_candidate_fast_forwards_without_replaying_the_patch_twice(self):
        previous = sync.merge_candidate(self.root, self.maintained, self.upstream)
        sync.git(self.root, "checkout", sync.MAINTAINED)
        maintained = self.commit("patch.txt", "LiveSync patch\nSecond fix\n")
        updated = sync.merge_candidate(self.root, maintained, self.upstream, previous)
        self.assertTrue(sync.ancestor(self.root, previous, updated))
        self.assertTrue(sync.ancestor(self.root, maintained, updated))
        self.assertEqual((self.root / "patch.txt").read_text(), "LiveSync patch\nSecond fix\n")
        self.assertEqual(sync.merge_candidate(self.root, maintained, self.upstream, updated), updated)

    def test_conflict_lists_files_and_leaves_maintained_branch_intact(self):
        self.maintained = self.commit("shared.txt", "fork change\n")
        sync.git(self.root, "checkout", "official")
        self.upstream = self.commit("shared.txt", "official change\n")
        with self.assertRaises(sync.IntegrationConflict) as caught:
            sync.merge_candidate(self.root, self.maintained, self.upstream)
        self.assertEqual(caught.exception.files, ["shared.txt"])
        self.assertEqual(sync.git(self.root, "rev-parse", sync.MAINTAINED), self.maintained)
        self.assertEqual(sync.git(self.root, "status", "--porcelain"), "")
        self.assertFalse((self.root / ".git/MERGE_HEAD").exists())

    def test_dirty_checkout_is_never_overwritten(self):
        path = self.root / "patch.txt"
        path.write_text("uncommitted user work\n")
        with self.assertRaisesRegex(ValueError, "clean disposable"):
            sync.merge_candidate(self.root, self.maintained, self.upstream)
        self.assertEqual(path.read_text(), "uncommitted user work\n")
        self.assertEqual(sync.git(self.root, "rev-parse", "HEAD"), self.maintained)

    def test_pins_follow_selected_upstream_and_historical_checks_are_not_new_proof(self):
        manifest = {"flutter": {"version": "3.47.1"}, "native": {"liveSyncPatchSha256": "kept"},
                    "upstream": {}, "checks": {"historical": {"forkSha": self.maintained}}}
        fixtures = {
            sync.MANIFEST: json.dumps(manifest),
            "mpv-build.lock.json": json.dumps({"repo": "edde746/mpv-build", "commit": "a" * 40}),
            ".github/actions/setup-flutter-git/action.yml": '$version = "3.48.2"\n$expectedCommit = "' + "b" * 40 + '"',
            "windows/tool/install-patched-engine.ps1": "$ExpectedEngine = '" + "c" * 40 + "'",
            "pubspec.yaml": "version: 2.21.0+160\n",
            ".github/workflows/livesync-dart.yml": "flutter-version: '3.47.1'\n",
            ".github/workflows/livesync-macos.yml": "flutter-version: '3.47.1'\n",
        }
        for name, text in fixtures.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        components = {"mpv": {"commit": "d" * 40}}
        sync.update_manifest(self.root, self.maintained, self.upstream, "2.21.0", components)
        updated = json.loads((self.root / sync.MANIFEST).read_text())
        self.assertEqual(updated["flutter"], {"version": "3.48.2", "revision": "b" * 40, "engine": "c" * 40})
        self.assertEqual(updated["native"]["components"], components)
        self.assertEqual(updated["native"]["liveSyncPatchSha256"], "kept")
        self.assertFalse(updated["integrationCandidate"]["validated"])
        self.assertEqual(updated["checks"], manifest["checks"])
        self.assertIn("3.48.2", (self.root / ".github/workflows/livesync-macos.yml").read_text())


class OrchestrationTests(unittest.TestCase):
    def test_unchanged_upstream_never_checks_out_pushes_or_dispatches(self):
        candidate = "a" * 40
        commands = []

        def git(root, *args):
            commands.append(args)
            return candidate if args[0] == "rev-parse" else ""

        report = {}
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": sync.FORK}), \
                patch.object(sync, "git", side_effect=git), patch.object(sync, "ancestor", return_value=True), \
                patch.object(sync, "api", return_value={"tag_name": "2.20.0"}), patch.object(sync, "output"):
            sync.prepare(Path("."), report)
        self.assertEqual(report["state"], "unchanged")
        self.assertFalse(any(command[0] in ("checkout", "push", "merge") for command in commands))

    def test_integration_cannot_write_from_an_unrelated_repository(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "other/repository"}):
            with self.assertRaisesRegex(ValueError, "restricted"):
                sync.prepare(Path("."), {})

    def test_only_marked_exact_sha_runs_are_reused_and_live_runs_are_not_restarted(self):
        candidate = "a" * 40
        def record(identifier, status, conclusion=None, title=None, revision=candidate):
            return {"id": identifier, "head_sha": revision, "event": "workflow_dispatch", "status": status,
                    "conclusion": conclusion, "display_title": title or f"LiveSync upstream {candidate}"}
        passed = record(1, "completed", "success")
        live = record(2, "in_progress")
        irrelevant = record(3, "in_progress", title="Manual renderer-only check")
        wrong_sha = record(4, "in_progress", revision="b" * 40)
        self.assertEqual(sync.matching_run([passed, live, irrelevant, wrong_sha], candidate), live)
        self.assertEqual(sync.matching_run([passed, irrelevant], candidate), passed)
        self.assertIsNone(sync.matching_run([record(5, "completed", "failure"), irrelevant], candidate))
        with self.assertRaisesRegex(ValueError, "Multiple live"):
            sync.matching_run([live, record(6, "queued")], candidate)

    def test_pr_is_not_published_from_incomplete_or_stale_validation(self):
        candidate = "a" * 40
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(sync, "api", return_value={"object": {"sha": candidate}}), patch.object(sync, "run") as run:
                with self.assertRaisesRegex(ValueError, "Missing successful"):
                    sync.publish_pr(candidate, {}, directory)
                run.assert_not_called()
            for number, kind in enumerate(sync.WORKFLOWS, 1):
                (directory / f"{kind}.json").write_text(json.dumps({
                    "candidateSha": candidate, "kind": kind, "conclusion": "success", "runId": number,
                }))
            with patch.object(sync, "api", side_effect=[{"object": {"sha": candidate}}, {
                "head_sha": "b" * 40, "conclusion": "success",
            }]), patch.object(sync, "run") as run:
                with self.assertRaisesRegex(ValueError, "Live GitHub"):
                    sync.publish_pr(candidate, {}, directory)
                run.assert_not_called()

    def test_existing_ready_pr_returns_to_draft_when_candidate_changes(self):
        commands = []
        def run(*args, **kwargs):
            commands.append(args)
            if args[1:3] == ("pr", "list"):
                return '[{"number": 42, "isDraft": false}]'
            if "--body-file" in args:
                self.assertIn("awaiting validation", Path(args[-1]).read_text())
            return ""
        with patch.object(sync, "run", side_effect=run):
            sync.mark_pr_pending("a" * 40)
        self.assertEqual(commands[1][:5], ("gh", "pr", "ready", "42", "--undo"))
        self.assertFalse(any(command[1:3] == ("pr", "create") for command in commands))


if __name__ == "__main__":
    unittest.main()

from contextlib import redirect_stdout
import io
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

MODULE = runpy.run_path(str(Path(__file__).parents[1] / "scripts/record-release.py"))
RECORD = MODULE["record_release"]
MANIFEST = MODULE["MANIFEST"]


class RecordReleaseTests(unittest.TestCase):
    def git(self, repo, *args):
        return subprocess.check_output(["git", *args], cwd=repo, text=True, stderr=subprocess.DEVNULL).strip()

    def commit(self, repo, message):
        self.git(repo, "add", ".")
        self.git(repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", message)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="record-release-test-")
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.remote, self.seed, self.runner = (root / name for name in ["remote.git", "seed", "runner"])
        subprocess.run(["git", "init", "--bare", "--initial-branch=master", str(self.remote)], check=True, capture_output=True)
        subprocess.run(["git", "clone", str(self.remote), str(self.seed)], check=True, capture_output=True)
        manifest = self.seed / MANIFEST
        manifest.parent.mkdir(parents=True)
        services = ["api", "frontend", "pdf-worker", "keycloak", "cie10", "migrate"]
        manifest.write_text('image_tags = {\n' + ''.join(f'  "{name}" = "old-{name}"\n' for name in services) + '}\n')
        (self.seed / "provider.lock").write_text("original lock\n")
        (self.seed / "notes.md").write_text("original notes\n")
        (self.seed / ".gitignore").write_text(".env.tmp\n")
        self.commit(self.seed, "initial")
        self.git(self.seed, "push", "origin", "master")
        subprocess.run(["git", "clone", str(self.remote), str(self.runner)], check=True, capture_output=True)
        self.git(self.runner, "checkout", "--detach")

    def update(self, repo, service, tag):
        MODULE["UPDATE_IMAGE"](repo / MANIFEST, service, tag)

    def record(self):
        with redirect_stdout(io.StringIO()):
            return RECORD(self.runner)

    def remote_images(self):
        self.git(self.seed, "fetch", "origin", "master")
        content = self.git(self.seed, "show", "origin/master:" + MANIFEST)
        path = Path(self.directory.name, "remote-images.tfvars")
        path.write_text(content + "\n")
        return MODULE["READ_IMAGES"](path)

    def test_detached_dirty_runner_publishes_only_manifest_and_preserves_other_changes(self):
        self.update(self.runner, "api", "1.0.0-8c52543")
        self.update(self.runner, "frontend", "1.0.0-d6291b5")
        (self.runner / "provider.lock").write_text("changed by init\n")
        (self.runner / "notes.md").write_text("staged unrelated value\n")
        self.git(self.runner, "add", "notes.md")
        (self.runner / ".env.tmp").write_text("private-value-never-commit\n")
        runner_head = self.git(self.runner, "rev-parse", "HEAD")
        self.assertTrue(self.record())
        self.assertEqual(self.git(self.runner, "rev-parse", "HEAD"), runner_head)
        self.assertEqual((self.runner / "provider.lock").read_text(), "changed by init\n")
        self.assertEqual(self.git(self.runner, "diff", "--cached", "--name-only"), "notes.md")
        self.assertEqual((self.runner / ".env.tmp").read_text(), "private-value-never-commit\n")
        images = self.remote_images()
        self.assertEqual(images["api"], "1.0.0-8c52543")
        self.assertEqual(images["frontend"], "1.0.0-d6291b5")
        self.assertEqual(images["cie10"], "old-cie10")
        self.assertEqual(self.git(self.seed, "diff-tree", "--no-commit-id", "--name-only", "-r", "origin/master"), MANIFEST)
        self.assertEqual(self.git(self.seed, "show", "origin/master:provider.lock"), "original lock")
        self.assertEqual(len(self.git(self.runner, "worktree", "list", "--porcelain").split("worktree ")) - 1, 1)

    def test_concurrent_other_component_and_documentation_changes_are_preserved(self):
        self.update(self.runner, "api", "new-api")
        self.update(self.seed, "frontend", "concurrent-frontend")
        (self.seed / "notes.md").write_text("concurrent notes\n")
        self.commit(self.seed, "parallel update")
        self.git(self.seed, "push", "origin", "master")
        self.assertTrue(self.record())
        images = self.remote_images()
        self.assertEqual(images["api"], "new-api")
        self.assertEqual(images["frontend"], "concurrent-frontend")
        self.assertEqual(self.git(self.seed, "show", "origin/master:notes.md"), "concurrent notes")

    def test_concurrent_different_tag_for_same_component_fails_without_overwriting(self):
        self.update(self.runner, "api", "verified-api")
        self.update(self.seed, "api", "concurrent-api")
        self.commit(self.seed, "another api release")
        self.git(self.seed, "push", "origin", "master")
        with self.assertRaisesRegex(RuntimeError, "Conflicto de tags en master: api"):
            self.record()
        self.assertEqual(self.remote_images()["api"], "concurrent-api")
        self.assertEqual(len(self.git(self.runner, "worktree", "list", "--porcelain").split("worktree ")) - 1, 1)

    def test_already_recorded_tags_are_idempotent(self):
        self.update(self.runner, "api", "verified-api")
        self.update(self.seed, "api", "verified-api")
        self.commit(self.seed, "api already registered")
        self.git(self.seed, "push", "origin", "master")
        head = self.git(self.seed, "rev-parse", "HEAD")
        self.assertFalse(self.record())
        self.assertEqual(self.git(self.remote, "rev-parse", "master"), head)

    def test_no_tag_changes_does_not_publish_dirty_unrelated_files(self):
        (self.runner / "provider.lock").write_text("dirty init lock\n")
        head = self.git(self.remote, "rev-parse", "master")
        self.assertFalse(self.record())
        self.assertEqual(self.git(self.remote, "rev-parse", "master"), head)

    def test_push_rejection_never_forces_remote_and_keeps_runner_changes(self):
        self.update(self.runner, "api", "verified-api")
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o700)
        head = self.git(self.remote, "rev-parse", "master")
        with self.assertRaisesRegex(RuntimeError, "Git push fallo"):
            self.record()
        self.assertEqual(self.git(self.remote, "rev-parse", "master"), head)
        self.assertEqual(MODULE["READ_IMAGES"](self.runner / MANIFEST)["api"], "verified-api")

    def test_verified_selection_never_registers_an_unselected_manifest_edit(self):
        self.update(self.runner, "api", "verified-api")
        self.update(self.runner, "frontend", "unselected-edit")
        with redirect_stdout(io.StringIO()):
            self.assertTrue(RECORD(self.runner, verified={"api": "verified-api"}))
        self.assertEqual(self.remote_images()["frontend"], "old-frontend")

    def test_selected_unchanged_tag_detects_concurrent_manifest_change(self):
        self.update(self.seed, "api", "concurrent-api")
        self.commit(self.seed, "api changed while queued")
        self.git(self.seed, "push", "origin", "master")
        with self.assertRaisesRegex(RuntimeError, "Conflicto de tags en master: api"):
            RECORD(self.runner, verified={"api": "old-api"})
        self.assertEqual(self.remote_images()["api"], "concurrent-api")

    def test_verified_tags_must_match_deployed_workspace(self):
        for verified in [{}, [], {"api": "not-the-deployed-tag"}, {"unknown": "old-api"}]:
            with self.subTest(verified=verified), self.assertRaises(ValueError):
                RECORD(self.runner, verified=verified)

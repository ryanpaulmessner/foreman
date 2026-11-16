"""Deploy contract tests: real local git, stubbed service/build/network commands."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "deploy/board-update"

STUB = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ["CALLS"], "a") as log:
    log.write(json.dumps([name, sys.argv[1:], os.getcwd(), os.environ.get("MIX_ENV")]) + "\\n")
if name == "curl":
    print(os.environ.get("HTTP", "200"), end="")
elif name == "gh":
    print(os.environ.get("ACTIVITY", "[[]]"))
elif name == "mix":
    if sys.argv[1] == "ecto.migrations":
        print(os.environ.get("MIGRATIONS", "Repo: Foreman.Repo\\n Status Migration ID Migration Name\\n up 20260101000000 initial"))
    elif sys.argv[1] == "escript.build":
        assert pathlib.Path("deps/marker").read_text() == "deps"
        pathlib.Path("foreman").write_text("new CLI")
        sys.exit(int(os.environ.get("FAIL_BUILD", "0")))
    elif sys.argv[1] == "ecto.migrate":
        sys.exit(int(os.environ.get("FAIL_MIGRATE", "0")))
sys.exit(int(os.environ.get("FAIL_" + name.upper(), "0")))
'''


class BoardUpdateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="board-update-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls"
        self.env = {**os.environ, "HOME": str(self.home), "CALLS": str(self.calls),
                    "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
                    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com"}
        for name in ("launchctl", "curl", "mix", "gh"):
            path = self.bin / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.origin = self.root / "origin.git"
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.origin))
        self.seed = self.root / "seed"
        self.git(self.root, "clone", str(self.origin), str(self.seed))
        self.commit(self.seed, "app", "initial")
        self.git(self.seed, "push", "origin", "main")
        self.checkout = self.root / "checkout"
        self.git(self.root, "clone", str(self.origin), str(self.checkout))
        # URL rewriting keeps fetch entirely local while exercising GitHub URL parsing.
        self.git(self.checkout, "remote", "set-url", "origin", "git@github.com:example/board.git")
        self.git(self.checkout, "config", f"url.{self.origin}.insteadOf", "git@github.com:example/board.git")
        self.initial = self.git(self.checkout, "rev-parse", "HEAD")
        self.state = self.home / ".local/state/foreman/board-deploy.json"

    def git(self, cwd, *args):
        result = subprocess.run(["git", *args], cwd=cwd, env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def commit(self, repo, name, content):
        (repo / name).write_text(content)
        self.git(repo, "add", name)
        self.git(repo, "commit", "-m", content)
        return self.git(repo, "rev-parse", "HEAD")

    def advance(self):
        sha = self.commit(self.seed, "app", "updated")
        self.git(self.seed, "push", "origin", "main")
        return sha

    def run_update(self, *args):
        return subprocess.run([str(SCRIPT), "--checkout", str(self.checkout), *args],
                              env=self.env, text=True, capture_output=True, timeout=20)

    def commands(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_malformed_checkpoint_is_not_treated_as_first_deploy(self):
        self.state.parent.mkdir(parents=True)
        self.state.write_text("{}")
        self.advance()
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED state", result.stdout)
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), self.initial)
        self.assertEqual(self.state.read_text(), "{}")

    def test_old_force_push_is_ignored_and_success_records_head(self):
        self.state.parent.mkdir(parents=True)
        self.state.write_text(json.dumps({"sha": self.initial, "checked_at": "2026-02-01T00:00:00Z", "repo": "example/board"}))
        self.env["ACTIVITY"] = json.dumps([[{"activity_type": "force_push", "ref": "refs/heads/main",
                                            "timestamp": "2026-01-01T00:00:00Z", "after": "old"}], []])
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(self.state.read_text())["sha"], self.initial)
        command = next(c for c in self.commands() if c[0] == "gh")
        self.assertIn("--paginate", command[1])
        self.assertIn("repos/example/board/activity?ref=refs/heads/main&activity_type=force_push&per_page=100", command[1])
        self.assertNotIn(["ecto.migrate"], [c[1] for c in self.commands()])

    def test_force_push_on_later_page_is_not_missed(self):
        self.env["ACTIVITY"] = json.dumps([[], [{"activity_type": "force_push", "ref": "refs/heads/main",
                                                "timestamp": "2099-01-01T00:00:00Z", "after": "later-page"}]])
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("later-page", result.stdout)
        self.assertFalse(self.state.exists())

    def test_github_failure_does_not_record_success(self):
        self.env["FAIL_GH"] = "1"
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED force-push", result.stdout)
        self.assertFalse(self.state.exists())

    def test_cli_build_failure_preserves_installed_binary_and_cleans_worktree(self):
        (self.checkout / "deps").mkdir()
        (self.checkout / "deps/marker").write_text("deps")
        target = self.home / ".local/bin/foreman"
        target.parent.mkdir(parents=True)
        target.write_text("old CLI")
        self.env["FAIL_BUILD"] = "1"
        result = self.run_update("--cli")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED cli", result.stdout)
        self.assertEqual(target.read_text(), "old CLI")
        self.assertEqual(self.git(self.checkout, "worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertFalse(self.state.exists())

    def test_migration_failure_prevents_restart(self):
        self.advance()
        self.env["MIGRATIONS"] = "Repo: Foreman.Repo\n down 20260202000000 add_column"
        self.env["FAIL_MIGRATE"] = "1"
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED migrations", result.stdout)
        self.assertNotIn("launchctl", [c[0] for c in self.commands()])
        self.assertFalse(self.state.exists())

    def test_non_main_branch_refused(self):
        self.git(self.checkout, "checkout", "-b", "feature")
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checkout must be on main", result.stdout)
        self.assertEqual(self.commands(), [])

    def test_failed_step_prints_remaining_skips_and_current_head(self):
        sha = self.advance()
        self.env["FAIL_LAUNCHCTL"] = "1"
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED restart", result.stdout)
        for step in ("health", "force-push", "cli", "record"):
            self.assertIn("skipped " + step, result.stdout)
        self.assertEqual(result.stdout.splitlines()[-1], "HEAD " + sha)
        self.assertNotIn("curl", [c[0] for c in self.commands()])
        self.assertFalse(self.state.exists())

    def test_concurrent_deploy_is_refused_before_fetch(self):
        self.advance()
        lock_path = self.home / ".local/state/foreman/board-deploy.lock"
        lock_path.parent.mkdir(parents=True)
        with lock_path.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another board-update", result.stdout)
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), self.initial)
        self.assertEqual(self.commands(), [])

    def test_retry_after_health_failure_restarts_even_when_head_is_unchanged(self):
        self.advance()
        self.env["HTTP"] = "503"
        failed = self.run_update("--timeout", "0.1")
        self.assertNotEqual(failed.returncode, 0)
        self.calls.unlink()
        self.env["HTTP"] = "200"
        retry = self.run_update()
        self.assertEqual(retry.returncode, 0, retry.stdout)
        self.assertIn("ok restart", retry.stdout)
        self.assertIn("ok health", retry.stdout)

    def test_dry_run_prints_all_steps_without_changes(self):
        self.advance()
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        result = self.run_update("--dry-run", "--cli")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for step in ("checkout", "fetch", "merge", "migrations", "restart", "health", "force-push", "cli", "state"):
            self.assertIn("skipped " + step, result.stdout)
        after = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(self.commands(), [])
        self.assertIn(self.initial, result.stdout)

    def test_cli_builds_in_scratch_worktree_and_installs_atomically(self):
        sha = self.advance()
        (self.checkout / "deps").mkdir()
        (self.checkout / "deps/marker").write_text("deps")
        target = self.home / ".local/bin/foreman"
        target.parent.mkdir(parents=True)
        target.write_text("old CLI")
        result = self.run_update("--cli")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(target.read_text(), "new CLI")
        self.assertTrue(os.access(target, os.X_OK))
        build = next(c for c in self.commands() if c[0:2] == ["mix", ["escript.build"]])
        self.assertNotEqual(build[2], str(self.checkout))
        self.assertEqual(build[3], "prod")
        self.assertFalse(Path(build[2]).exists())
        self.assertFalse((self.checkout / "foreman").exists())
        self.assertEqual(self.git(self.checkout, "worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertIn("ok cli: installed " + sha, result.stdout)

    def test_force_push_since_previous_deploy_fails_after_restart(self):
        self.state.parent.mkdir(parents=True)
        previous = {"sha": self.initial, "checked_at": "2026-01-01T00:00:00Z", "repo": "example/board"}
        self.state.write_text(json.dumps(previous))
        self.advance()
        self.env["ACTIVITY"] = json.dumps([[{"activity_type": "force_push", "ref": "refs/heads/main",
                                            "timestamp": "2026-02-01T00:00:00Z", "after": "abc123"}]])
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED force-push", result.stdout)
        self.assertIn("abc123", result.stdout)
        self.assertLess(result.stdout.index("ok restart"), result.stdout.index("FAILED force-push"))
        self.assertEqual(json.loads(self.state.read_text()), previous)

    def test_health_timeout_fails_without_recording_success(self):
        self.advance()
        self.env["HTTP"] = "503"
        result = self.run_update("--timeout", "0.15")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED health", result.stdout)
        self.assertIn("timeout", result.stdout)
        self.assertFalse(self.state.exists())

    def test_pending_migration_runs_before_restart(self):
        self.advance()
        self.env["MIGRATIONS"] = "Repo: Foreman.Repo\n down 20260202000000 add_column"
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("20260202000000 add_column", result.stdout)
        commands = self.commands()
        migrate = next(i for i, c in enumerate(commands) if c[0:2] == ["mix", ["ecto.migrate"]])
        restart = next(i for i, c in enumerate(commands) if c[0] == "launchctl")
        self.assertLess(migrate, restart)

    def test_diverged_conflicting_history_stops_without_merge_commit_or_reset(self):
        local = self.commit(self.checkout, "app", "local edit")
        self.advance()
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("resolve the merge", result.stdout)
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), local)
        self.assertTrue(self.git(self.checkout, "ls-files", "--unmerged"))
        self.assertEqual(self.commands(), [])
        again = self.run_update()
        self.assertIn("FAILED checkout", again.stdout)

    def test_local_ticket_commits_and_untracked_files_are_preserved(self):
        local = self.commit(self.checkout, "ticket", "local ticket")
        (self.checkout / "untracked").write_text("keep")
        remote = self.advance()
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD^1"), local)
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD^2"), remote)
        self.assertEqual((self.checkout / "untracked").read_text(), "keep")

    def test_dirty_tracked_checkout_refused_before_fetch(self):
        self.advance()
        (self.checkout / "app").write_text("dirty")
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dirty", result.stdout)
        self.assertEqual(self.git(self.checkout, "rev-parse", "origin/main"), self.initial)
        self.assertEqual((self.checkout / "app").read_text(), "dirty")
        self.assertEqual(self.commands(), [])

    def test_fast_forward_restarts_and_checks_health(self):
        sha = self.advance()
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), sha)
        commands = self.commands()
        restart = next(c for c in commands if c[0] == "launchctl")
        self.assertEqual(restart[1], ["kickstart", "-k", f"gui/{os.getuid()}/com.ryanpaulmessner.foreman"])
        self.assertIn("http://127.0.0.1:4747/sessions", next(c for c in commands if c[0] == "curl")[1])
        self.assertIn(sha, result.stdout)

    def test_up_to_date_does_not_restart(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("skipped restart", result.stdout)
        self.assertNotIn("launchctl", [c[0] for c in self.commands()])
        self.assertIn(self.initial, result.stdout)


if __name__ == "__main__":
    unittest.main()

import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]
CONFIG = '''{
      dmTools = {
        tool = {
          version = "1.0.0";
        };
      };
      unrelated = "keep";
}
'''
MOCK_CODEX = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
if sys.argv[1:] == ["--version"]:
    print("codex-test")
    sys.exit(0)
Path(os.environ["TEST_CALLED"]).write_text("called")
mode = os.environ.get("TEST_MODE", "complete")
output = Path(sys.argv[sys.argv.index("--output-last-message") + 1])
run = Path(os.environ["FLAKES_MAINTENANCE_RUN_DIR"])
scripts = (run / "discovered-updaters.txt").read_text().splitlines()
audit = Path(os.environ["FLAKES_MAINTENANCE_UPDATER_AUDIT"])
audit.write_text("".join(f"{script}\t1\t0\n" for script in scripts))
if mode == "last_failure":
    with audit.open("a") as handle:
        handle.write(f"{scripts[0]}\t2\t1\n")
if mode == "missing_audit":
    audit.write_text("")
home = Path(os.environ["FLAKES_MAINTENANCE_HOME_MANAGER_REPO"])
if mode == "outside_edit":
    with (home / "flake.nix").open("a") as handle:
        handle.write("\nunrelated_extra = true;\n")
if mode == "darwin_edit":
    (home / "darwin/data.bin").write_bytes(bytes([255, 0, 128]))
if mode in ("protected_input", "allowed_transitive"):
    lock = json.loads((home / "flake.lock").read_text())
    key = "nixpkgs" if mode == "protected_input" else "tool-child"
    lock["nodes"][key]["locked"]["rev"] = "changed"
    (home / "flake.lock").write_text(json.dumps(lock))
output.write_text(json.dumps({
    "status": "partial" if mode == "partial" else "complete",
    "flakes_pushed": True,
    "home_manager": {
        "non_darwin_pins_updated": True, "switch_completed": True,
        "dirty_state_preserved": True, "root_inputs_current": True,
        "profile_after": str(Path(os.environ["TEST_ACTIVE_PROFILE"]).resolve()),
    },
    "blocked_reasons": [],
    "updater_results": [
        {"script": s, "attempts": 1, "final_exit_code": 0} for s in scripts
    ],
}))
'''

class RunnerTests(unittest.TestCase):
    def command(self, *args):
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.repo = self.root / "flakes"
        self.hm = self.root / "home-manager"
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.state = self.root / "state"
        for path in (self.repo, self.hm, self.home, self.bin):
            path.mkdir()
        shutil.copytree(SOURCE, self.repo / "maintenance")
        tool = self.repo / "tool"
        (tool / "scripts").mkdir(parents=True)
        # Invocation through bash must work without the executable bit.
        (tool / "scripts/update-version.sh").write_text("#!/bin/bash\nexit 0\n")
        (tool / "releases.json").write_text(json.dumps({"latest": "1.0.0"}))
        self.command("git", "init", "-q", "-b", "master", str(self.repo))
        self.command("git", "-C", str(self.repo), "config", "user.email", "test@example.invalid")
        self.command("git", "-C", str(self.repo), "config", "user.name", "test")
        self.command("git", "-C", str(self.repo), "add", "maintenance", "tool")
        self.command("git", "-C", str(self.repo), "commit", "-qm", "initial")
        head = self.command("git", "-C", str(self.repo), "rev-parse", "HEAD")
        remote = self.root / "remote.git"
        self.command("git", "init", "--bare", "-q", str(remote))
        self.command("git", "-C", str(self.repo), "remote", "add", "origin", str(remote))
        self.command("git", "-C", str(self.repo), "push", "-q", "origin", "master")
        self.command("git", "init", "-q", str(self.hm))
        for name in ("flake.nix", "flake.wsl.nix"):
            (self.hm / name).write_text(CONFIG)
        (self.hm / "olares.nix").write_text("{ dmTools = {}; }\n")
        (self.hm / "darwin").mkdir()
        (self.hm / "darwin/flake.nix").write_text(CONFIG)
        (self.hm / "flake.lock").write_text(json.dumps({
            "root": "root", "nodes": {
                "root": {"inputs": {"tool": "tool", "nixpkgs": "nixpkgs"}},
                "tool": {
                    "original": {"url": "https://github.com/da-moon/flakes.git?dir=tool"},
                    "locked": {"rev": head}, "inputs": {"child": "tool-child"},
                },
                "tool-child": {"locked": {"rev": "old-child"}},
                "nixpkgs": {"locked": {"rev": "fixed"}},
            },
        }))
        self.expected = self.root / "generation"
        self.expected.mkdir()
        self.profile = self.home / ".local/state/nix/profiles/home-manager"
        self.profile.parent.mkdir(parents=True)
        self.profile.symlink_to(self.expected)
        codex = self.bin / "codex"
        codex.write_text(MOCK_CODEX)
        codex.chmod(0o755)
        nix = self.bin / "nix"
        nix.write_text("#!/bin/sh\nprintf '%s' \"$TEST_EXPECTED_PROFILE\"\n")
        nix.chmod(0o755)
        self.marker = self.root / "called"
        self.env = {
            **os.environ, "HOME": str(self.home), "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FLAKES_REPO": str(self.repo), "HOME_MANAGER_REPO": str(self.hm),
            "XDG_STATE_HOME": str(self.state), "TEST_CALLED": str(self.marker),
            "TEST_EXPECTED_PROFILE": str(self.expected), "TEST_ACTIVE_PROFILE": str(self.profile),
        }

    def run_job(self, mode="complete"):
        return subprocess.run(
            [str(self.repo / "maintenance/run.sh")],
            env={**self.env, "TEST_MODE": mode}, text=True, capture_output=True,
        )

    def assert_failure(self, mode, message):
        result = self.run_job(mode)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.marker.exists(), "fake Codex was not invoked")
        self.assertIn(message, result.stderr)

    def test_complete_run_and_private_logs(self):
        result = self.run_job()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("COMPLETE:", result.stdout)
        run = next((self.state / "flakes-maintenance/logs").iterdir())
        self.assertEqual(run.stat().st_mode & 0o777, 0o700)
        self.assertEqual((run / "result.json").stat().st_mode & 0o777, 0o600)

    def test_partial_result_is_not_success(self):
        self.assert_failure("partial", "Codex reported an incomplete result")

    def test_later_failed_attempt_invalidates_earlier_success(self):
        self.assert_failure("last_failure", "an updater audit ends in failure")

    def test_missing_audit_is_rejected(self):
        self.assert_failure("missing_audit", "updater audit omits a discovered script")

    def test_stale_wsl_pin_is_rejected(self):
        (self.hm / "flake.wsl.nix").write_text(CONFIG.replace("1.0.0", "0.9.0"))
        self.assert_failure("complete", "pin tool is not latest")

    def test_unrelated_config_change_is_rejected(self):
        self.assert_failure("outside_edit", "Home Manager changed outside")

    def test_root_locked_data_is_protected(self):
        self.assert_failure("protected_input", "Home Manager changed outside")

    def test_darwin_non_nix_files_are_protected(self):
        self.assert_failure("darwin_edit", "Home Manager changed outside")

    def test_tool_transitive_refresh_is_allowed(self):
        result = self.run_job("allowed_transitive")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_old_generation_is_not_a_completed_switch(self):
        old = self.root / "old-generation"
        old.mkdir()
        self.profile.unlink()
        self.profile.symlink_to(old)
        self.assert_failure("complete", "active Home Manager profile differs")

    def test_dirty_checkout_does_not_start_codex(self):
        (self.repo / "unfinished").write_text("user work")
        result = self.run_job()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertIn("worktree is dirty", result.stderr)

    def test_overlap_does_not_start_codex(self):
        lock = self.state / "flakes-maintenance/run.lock"
        lock.parent.mkdir(parents=True)
        with lock.open("w") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_job()
        self.assertEqual(result.returncode, 75)
        self.assertFalse(self.marker.exists())

if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Exercise updater ordering and failure handling without installing real software."""
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).with_name("update.sh").resolve()


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vox-update-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "checkout with spaces"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "Package.swift").touch()
        (self.repo / "scripts/bundle-app.sh").touch()
        self.installed = self.root / "installed/Vox.app"
        self.installed.parent.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.log"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        UPDATE_LOG=str(self.log), UPDATE_PROCESSES="")
        self.env.pop("DEVELOPER_ID", None)
        self.stub("uname", 'echo Darwin')
        self.stub("ps", 'printf "%s" "${UPDATE_PROCESSES:-}"')
        self.stub("git", '''
printf 'git %s\\n' "$*" >> "$UPDATE_LOG"
if [[ "$1" == -C ]]; then
  [[ "$3" != status ]] || printf "%s" "${UPDATE_SUBMODULE_DIRTY:-}"
  exit 0
fi
case "$1" in
  branch) echo "${UPDATE_BRANCH:-main}" ;;
  status) printf "%s" "${UPDATE_DIRTY:-}" ;;
  pull) exit "${UPDATE_PULL_STATUS:-0}" ;;
esac
''')
        # Logs whether the running app was still alive at each make step.
        self.stub("make", '''
state=""
if [[ -n "${UPDATE_WATCH_PID:-}" ]]; then
  if kill -0 "$UPDATE_WATCH_PID" 2>/dev/null; then state=" [app running]"; else state=" [app stopped]"; fi
fi
printf 'make %s%s\\n' "$*" "$state" >> "$UPDATE_LOG"
if [[ "$1" == install ]]; then exit "${UPDATE_INSTALL_STATUS:-0}"; fi
[[ "${UPDATE_BUILD_FAIL:-0}" == 0 ]] || exit 9
for arg in "$@"; do
  case "$arg" in
    APP_BUNDLE=*)
      bundle="${arg#APP_BUNDLE=}"
      mkdir -p "$bundle/Contents/MacOS"
      printf 'new app' > "$bundle/Contents/MacOS/Vox" ;;
  esac
done
''')
        self.stub("codesign", 'echo "TeamIdentifier=${UPDATE_TEAM:-not set}" >&2')
        self.stub("open", 'printf "open %s\\n" "$1" >> "$UPDATE_LOG"')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -e\n" + body + "\n")
        path.chmod(0o755)

    def run_update(self, *args, app=None, cwd=None, timeout=20):
        # Explicit destination isolates tests from /Applications on the host.
        app = [] if app is False else ["--app", str(app or self.installed)]
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), "--repo", str(self.repo), *app, *args],
            env=self.env, text=True, capture_output=True, timeout=timeout, cwd=cwd,
        )

    def commands(self):
        return self.log.read_text() if self.log.exists() else ""

    def running_app(self, bundle=None, ignore_term=False):
        command = ["/bin/bash", "-c", 'trap "" TERM; while true; do sleep 1; done'] \
            if ignore_term else ["/bin/sleep", "60"]
        child = subprocess.Popen(command)
        # Reap promptly after the updater terminates it so kill -0 sees it exit.
        waiter = threading.Thread(target=child.wait, daemon=True)
        waiter.start()
        self.env["UPDATE_PROCESSES"] += f"{child.pid} {bundle or self.installed}/Contents/MacOS/Vox\n"

        def cleanup():
            if child.poll() is None:
                child.kill()
            waiter.join(timeout=5)

        self.addCleanup(cleanup)
        return child

    def assert_in_order(self, commands, expected):
        positions = [commands.index(command) for command in expected]
        self.assertEqual(positions, sorted(positions), commands)

    def test_update_orders_pull_build_install_quit_and_restart(self):
        (self.repo / "vendor/whisper.cpp/.git").mkdir(parents=True)
        child = self.running_app()
        self.env["UPDATE_WATCH_PID"] = str(child.pid)
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(child.poll())
        self.assert_in_order(self.commands(), [
            "git status --porcelain --ignore-submodules=all",
            "git pull --ff-only origin main",
            "git -C vendor/whisper.cpp checkout -- bindings/javascript/package.json",
            "git submodule update --init --recursive",
            f"make app sign APP_BUNDLE={self.installed.parent}/.vox-update.",
            "make install [app running]",
            f"open {self.installed}",
        ])
        self.assertNotIn("-B", self.commands())
        self.assertEqual((self.installed / "Contents/MacOS/Vox").read_text(), "new app")

    def test_dirty_checkout_and_other_branches_never_pull_or_build(self):
        for variable, value in [("UPDATE_DIRTY", " M README.md"), ("UPDATE_BRANCH", "feature")]:
            with self.subTest(variable=variable):
                self.env[variable] = value
                result = self.run_update()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("git pull", self.commands())
                self.assertNotIn("make ", self.commands())
                del self.env[variable]

    def test_submodule_edits_block_pull_except_the_generated_file(self):
        (self.repo / "vendor/whisper.cpp/.git").mkdir(parents=True)
        self.env["UPDATE_SUBMODULE_DIRTY"] = " M src/whisper.cpp\n"
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local edits", result.stderr)
        self.assertNotIn("git pull", self.commands())

        self.env["UPDATE_SUBMODULE_DIRTY"] = " M bindings/javascript/package.json\n"
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("git submodule update", self.commands())

    def test_failed_pull_does_not_build(self):
        self.env["UPDATE_PULL_STATUS"] = "1"
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("make ", self.commands())

    def test_failed_build_leaves_running_app_alive_and_does_not_install(self):
        child = self.running_app()
        self.env["UPDATE_BUILD_FAIL"] = "1"
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(child.poll())
        self.assertNotIn("make install", self.commands())
        self.assertNotIn("open ", self.commands())
        self.assertEqual(list(self.installed.parent.glob(".vox-update.*")), [])

    def test_failed_cli_install_leaves_running_app_alive(self):
        child = self.running_app()
        self.env["UPDATE_INSTALL_STATUS"] = "2"
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(child.poll())
        self.assertFalse(self.installed.exists())
        self.assertNotIn("open ", self.commands())

    def test_local_reinstall_skips_git_and_can_leave_app_closed(self):
        child = self.running_app()
        self.env["UPDATE_BRANCH"] = "feature"
        self.env["UPDATE_DIRTY"] = " M README.md"
        result = self.run_update("--no-pull", "--no-restart")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(child.poll())
        self.assertNotIn("git ", self.commands())
        self.assertIn("make install", self.commands())
        self.assertNotIn("open ", self.commands())

    def test_closed_app_is_not_launched(self):
        result = self.run_update("--no-pull")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("open ", self.commands())

    def test_default_destination_follows_the_running_app(self):
        self.running_app()
        result = self.run_update("--no-pull", app=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed / "Contents/MacOS/Vox").read_text(), "new app")
        self.assertIn(f"open {self.installed}", self.commands())

    def test_dist_bundle_is_staged_not_rebuilt_in_place(self):
        dist = self.repo / "dist/Vox.app"
        (dist / "Contents/MacOS").mkdir(parents=True)
        (dist / "Contents/MacOS/Vox").write_text("old app")
        child = self.running_app(bundle=dist)
        self.env["UPDATE_WATCH_PID"] = str(child.pid)
        result = self.run_update("--no-pull", app=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"make app sign APP_BUNDLE={dist.parent}/.vox-update.", self.commands())
        self.assertEqual((dist / "Contents/MacOS/Vox").read_text(), "new app")
        self.assertIn(f"open {dist}", self.commands())

    def test_relative_app_path_resolves_against_the_callers_directory(self):
        result = self.run_update("--no-pull", app="installed/Vox.app", cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed / "Contents/MacOS/Vox").read_text(), "new app")
        self.assertFalse((self.repo / "installed").exists())

    def test_explicit_app_only_stops_copies_of_that_bundle(self):
        target = self.running_app()
        other = self.running_app(bundle=self.root / "other/Vox.app")
        result = self.run_update("--no-pull")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(target.poll())
        self.assertIsNone(other.poll())

    def test_app_replacement_removes_obsolete_bundle_files(self):
        self.installed.mkdir()
        (self.installed / "obsolete-signature").touch()
        result = self.run_update("--no-pull")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.installed / "obsolete-signature").exists())
        self.assertEqual((self.installed / "Contents/MacOS/Vox").read_text(), "new app")
        self.assertEqual(list(self.installed.parent.glob(".vox-update.*")), [])

    def test_developer_id_install_requires_developer_id(self):
        self.installed.mkdir()
        self.env["UPDATE_TEAM"] = "ABCDE12345"
        result = self.run_update("--no-pull")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DEVELOPER_ID", result.stderr)
        self.assertNotIn("make ", self.commands())

        self.env["DEVELOPER_ID"] = "Developer ID Application: Example (ABCDE12345)"
        result = self.run_update("--no-pull")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_app_that_will_not_quit_is_left_in_place(self):
        self.installed.mkdir()
        (self.installed / "old").touch()
        child = self.running_app(ignore_term=True)
        result = self.run_update("--no-pull", timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not quit", result.stderr)
        self.assertIsNone(child.poll())
        self.assertTrue((self.installed / "old").exists())
        self.assertEqual(list(self.installed.parent.glob(".vox-update.*")), [])

    def test_multiple_running_locations_require_an_explicit_destination(self):
        child = self.running_app()
        self.env["UPDATE_PROCESSES"] += f"99999999 {self.root}/other/Vox.app/Contents/MacOS/Vox\n"
        result = self.run_update(app=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Multiple Vox copies", result.stderr)
        self.assertIsNone(child.poll())
        self.assertNotIn("git pull", self.commands())
        self.assertNotIn("make ", self.commands())


if __name__ == "__main__":
    unittest.main()

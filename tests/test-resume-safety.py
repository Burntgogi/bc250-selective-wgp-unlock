#!/usr/bin/env python3
"""Hardware-free execution checks for the reboot-resume trust boundary."""

import getpass
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
FILES = (
    "bc250-wgp-autotest.sh",
    "bc250-mode7-mask.sh",
    "bc250-fast-kernel-suite.sh",
    "bc250-compute-verify.sh",
    "bc250-quant-matmul-verify.sh",
)


class ResumeSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bc250-resume-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        for name in FILES:
            shutil.copy2(SCRIPTS / name, self.checkout / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Model root ownership only; modes, symlinks, copies, and execution use
        # the real filesystem. Ancestors outside this private sandbox are not
        # installation targets (notably the host's sticky /tmp directory).
        self.command("stat", f'''#!{sys.executable}
import os, stat, sys
path = os.path.abspath(sys.argv[-1])
root = os.environ["TEST_ROOT"]
if path == root or path.startswith(root + os.sep):
    owner = 1000 if path == os.environ.get("UNTRUSTED_PATH") else 0
    mode = stat.S_IMODE(os.lstat(path).st_mode)
else:
    owner, mode = 0, 0o755
print(str(owner) + " " + format(mode, "o"))
''')
        self.command("id", '''#!/usr/bin/env bash
if [ "$#" = 1 ] && [ "$1" = -u ]; then
    printf '0\n'
else
    /usr/bin/id "$@"
fi
''')
        for name in ("systemctl", "loginctl", "usermod", "runuser", "reboot", "vulkaninfo"):
            self.command(name, "#!/usr/bin/env bash\nexit 88\n")
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("BC250_") and key not in {
                "CPATH", "LIBRARY_PATH", "LD_LIBRARY_PATH", "VK_ICD_FILENAMES",
                "VK_DRIVER_FILES", "VK_LAYER_PATH",
            }
        }
        self.env.update(
            TEST_ROOT=str(self.root),
            SOURCE_SCRIPT=str(self.checkout / FILES[0]),
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            BC250_AUTOTEST_INSTALL_DIR=str(self.root / "installed space%literal${HOME}"),
            BC250_AUTOTEST_STATE=str(self.root / "state space%literal"),
            BC250_AUTOTEST_SERVICE="bc250-test-custom.service",
            BC250_AUTOTEST_USER=getpass.getuser(),
            BC250_MODE7_CONF=str(self.root / "mode7.conf"),
        )

    def command(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def shell(self, body, **environment):
        return subprocess.run(
            ["bash", "-c", 'source "$SOURCE_SCRIPT"\n' + body],
            env={**self.env, **environment},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def install(self, **environment):
        result = self.shell('''
install_snapshot
SERVICE_FILE="$TEST_ROOT/generated.service"
ensure_user_access() { :; }
systemctl() { :; }
install_service
printf '%s\\n' "$INSTALLED_SELF" "$MASK" "$VERIFY_BIN" "$VERIFIER_ENV_FILE"
''', **environment)
        self.assert_success(result)
        return tuple(Path(line) for line in result.stdout.splitlines())

    def service(self):
        environment = {}
        command = None
        for line in (self.root / "generated.service").read_text().splitlines():
            if line.startswith("Environment="):
                argument = json.loads(line.partition("=")[2]).replace("%%", "%")
                name, _, value = argument.partition("=")
                environment[name] = value
            elif line.startswith("ExecStart="):
                command = [part.replace("%%", "%").replace("$$", "$")
                           for part in shlex.split(line.partition("=")[2])]
        self.assertIsNotNone(command)
        return command, environment

    def test_service_and_helpers_execute_snapshot_after_checkout_changes(self):
        expected_queue = subprocess.run(
            ["bash", str(self.checkout / FILES[0]), "queue", "singles"],
            env=self.env, text=True, capture_output=True, check=True,
        ).stdout
        executable, mask, verifier, environment_file = self.install()
        command, environment = self.service()
        for name in FILES:
            installed = executable.parent / name
            self.assertEqual(stat.S_IMODE(installed.stat().st_mode) & 0o022, 0)
            (self.checkout / name).write_text("#!/usr/bin/env bash\nexit 91\n")
        launch_env = {**self.env, **environment}
        resumed = subprocess.run(command, env=launch_env, text=True, capture_output=True)
        self.assert_success(resumed)
        queue = subprocess.run([str(executable), "queue", "singles"],
                               env=launch_env, text=True, capture_output=True)
        self.assert_success(queue)
        self.assertEqual(queue.stdout, expected_queue)
        planned = subprocess.run([environment["BC250_MODE7_MASK_SCRIPT"], "plan-extra-set", "0.0.3"],
                                 env=launch_env, text=True, capture_output=True)
        self.assert_success(planned)
        quant = subprocess.run([environment["BC250_AUTOTEST_VERIFY_BIN"], "quant-matmul", "--help"],
                               env=launch_env, text=True, capture_output=True)
        self.assert_success(quant)
        compute = subprocess.run([environment["BC250_AUTOTEST_VERIFY_BIN"], "custom", "0", "1", "1"],
                                 env=launch_env, text=True, capture_output=True)
        self.assertEqual(compute.returncode, 2, compute.stderr)

    def test_writable_destination_or_parent_fails_without_installing(self):
        for name, writable_parent in (("destination", False), ("parent", True)):
            with self.subTest(name=name):
                parent = self.root / name
                parent.mkdir(mode=0o755)
                destination = parent / "installed"
                destination.mkdir(mode=0o755)
                (parent if writable_parent else destination).chmod(0o775)
                result = self.shell("install_snapshot", BC250_AUTOTEST_INSTALL_DIR=str(destination))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(destination.iterdir()), [])

    def test_nonroot_destination_owner_fails_without_installing(self):
        destination = self.root / "foreign"
        destination.mkdir(mode=0o755)
        result = self.shell("install_snapshot", BC250_AUTOTEST_INSTALL_DIR=str(destination),
                            UNTRUSTED_PATH=str(destination))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(destination.iterdir()), [])

    def test_symlink_destination_and_parent_fail_without_touching_target(self):
        target = self.root / "target"
        target.mkdir()
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        for destination in (link, link / "installed"):
            result = self.shell("install_snapshot", BC250_AUTOTEST_INSTALL_DIR=str(destination))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(target.iterdir()), [])

    def test_custom_mask_rejects_foreign_owner_and_symlinks(self):
        helper = self.root / "custom-mask"
        shutil.copy2(SCRIPTS / FILES[1], helper)
        result = self.shell("install_snapshot", BC250_MODE7_MASK_SCRIPT=str(helper),
                            UNTRUSTED_PATH=str(helper))
        self.assertNotEqual(result.returncode, 0)
        link = self.root / "mask-link"
        link.symlink_to(helper)
        result = self.shell("install_snapshot", BC250_MODE7_MASK_SCRIPT=str(link))
        self.assertNotEqual(result.returncode, 0)

    def test_verifier_search_paths_never_enter_root_service_environment(self):
        self.install(
            BC250_AUTOTEST_USER="nobody",
            BC250_VULKAN_PREFIX="/user/vulkan prefix",
            CPATH="/user/include path",
            LD_LIBRARY_PATH="/user/library path",
        )
        _, environment = self.service()
        self.assertNotIn("LD_LIBRARY_PATH", environment)
        self.assertNotIn("CPATH", environment)
        self.assertNotIn("BC250_VULKAN_PREFIX", environment)

    def test_root_verifier_rejects_code_search_overrides_before_install(self):
        unsafe = self.root / "user-code"
        unsafe.mkdir(mode=0o777)
        unsafe.chmod(0o777)
        for name in ("BC250_VULKAN_PREFIX", "CPATH", "LIBRARY_PATH",
                     "LD_LIBRARY_PATH", "VK_ICD_FILENAMES", "VK_DRIVER_FILES",
                     "VK_LAYER_PATH"):
            with self.subTest(name=name):
                result = self.shell(
                    "install_snapshot", BC250_AUTOTEST_USER="root",
                    **{name: str(unsafe)},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(Path(self.env["BC250_AUTOTEST_INSTALL_DIR"]).exists())

    def test_root_verifier_revalidates_persisted_environment_before_execution(self):
        executable, _, _, environment_file = self.install()
        environment_file.write_bytes(b"CPATH=/user/mutable/headers\0")
        result = self.shell('''
RUN_USER=root
run_as_user_logged "$TEST_ROOT/root-verifier.log" /usr/bin/true
''', SOURCE_SCRIPT=str(executable), BC250_AUTOTEST_ENV_FILE=str(environment_file))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "root-verifier.log").exists())

    def test_mask_config_rejects_writable_parent_and_symlink(self):
        parent = self.root / "user-config"
        parent.mkdir()
        parent.chmod(0o777)
        config = parent / "mode7.conf"
        result = self.shell("install_snapshot", BC250_MODE7_CONF=str(config))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(config.exists())
        target = self.root / "config-target"
        target.write_text("unchanged")
        link = self.root / "config-link"
        link.symlink_to(target)
        result = self.shell("install_snapshot", BC250_MODE7_CONF=str(link))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), "unchanged")

    def test_resume_revalidates_persisted_mask_config_ownership(self):
        config = Path(self.env["BC250_MODE7_CONF"])
        config.write_text("unchanged")
        config.chmod(0o644)
        self.install()
        command, environment = self.service()
        result = subprocess.run(
            command, env={**self.env, **environment, "UNTRUSTED_PATH": str(config)},
            text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_text(), "unchanged")


    def test_untrusted_state_is_never_sourced(self):
        directory = Path(self.env["BC250_AUTOTEST_STATE"])
        directory.mkdir()
        state = directory / "state"
        marker = self.root / "sourced"
        state.write_text(f"touch {shlex.quote(str(marker))}\n")
        result = self.shell("load_state", UNTRUSTED_PATH=str(state))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())

    def test_service_destination_symlink_fails_before_host_commands(self):
        target = self.root / "service-target"
        target.write_text("unchanged")
        service = self.root / "custom.service"
        service.symlink_to(target)
        result = self.shell('''
install_snapshot
SERVICE_FILE="$TEST_ROOT/custom.service"
install_service
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), "unchanged")


if __name__ == "__main__":
    unittest.main()

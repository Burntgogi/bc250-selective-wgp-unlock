#!/usr/bin/env python3
"""Hardware-free regression checks for the privileged build's trust boundaries."""

import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/bc250-enable-40cu.sh"


class BuildSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bc250-build-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.source = self.root / "source"
        self.amdgpu = self.source / "drivers/gpu/drm/amd/amdgpu"
        self.amdgpu.mkdir(parents=True)
        (self.amdgpu / "gfx_v10_0.c").write_text(
            "/* bc250_cc_write_mode coherent-disable-cus */\n"
        )
        (self.root / "kernel/build").mkdir(parents=True)
        self.package = self.root / "linux-source.tar"
        with tarfile.open(self.package, "w") as archive:
            archive.add(self.source, arcname="linux-source-test")
        self.command(
            "make",
            '''#!/usr/bin/env bash
set -eu
module_dir=""
for arg in "$@"; do
    case "$arg" in M=*) module_dir="${arg#M=}" ;; esac
done
[ -n "$module_dir" ]
printf 'compiler output must not enter the module path\n'
case "${MAKE_MODE:-success}" in
    fail) exit 42 ;;
    fail-with-output)
        printf 'bc250_cc_write_mode\\nfailed build artifact\\n' > "$module_dir/amdgpu.ko"
        exit 42 ;;
    no-output) exit 0 ;;
    *) printf 'bc250_cc_write_mode\nnew module\n' > "$module_dir/amdgpu.ko" ;;
esac
''',
        )
        self.env = os.environ.copy()
        self.env.update(
            SOURCE_SCRIPT=str(SCRIPT),
            TEST_ROOT=str(self.root),
            SOURCE_PACKAGE=str(self.package),
            TMPDIR=str(self.tmp),
            PATH=str(self.bin) + os.pathsep + self.env["PATH"],
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

    def lifecycle(self, **environment):
        # Bypass only host hardware/dependency checks and privileged installation.
        # Extraction, patch recognition, build output and lifecycle are real code.
        return self.shell(
            '''
check_bc250() { :; }
check_deps() { :; }
find_source() {
    printf '%s\\n' "$BUILDDIR" "$(stat -c %a "$BUILDDIR")" >> "$TEST_ROOT/workspaces"
    extract_source "$SOURCE_PACKAGE"
}
install_module() { cp -- "$1" "$TEST_ROOT/installed.ko"; }
# A caller-supplied old workspace must not survive the per-build allocation.
BUILDDIR="$TMPDIR/bc250-40cu-build"
do_build
''',
            **environment,
        )

    def test_each_build_is_private_fresh_and_cleaned(self):
        predictable = self.tmp / "bc250-40cu-build"
        old_source = predictable / "src/drivers/gpu/drm/amd/amdgpu"
        old_source.mkdir(parents=True)
        (old_source / "gfx_v10_0.c").write_text("old untrusted source\n")
        (old_source / "amdgpu.ko").write_text("old untrusted module\n")
        sentinel = predictable / "sentinel"
        sentinel.write_text("untouched\n")
        self.assert_success(self.lifecycle())
        self.assert_success(self.lifecycle())
        records = (self.root / "workspaces").read_text().splitlines()
        workspaces = [Path(records[0]), Path(records[2])]
        self.assertEqual(records[1::2], ["700", "700"])
        self.assertNotEqual(workspaces[0], workspaces[1])
        for workspace in workspaces:
            self.assertNotEqual(workspace, predictable)
            self.assertFalse(workspace.exists())
        self.assertEqual(sentinel.read_text(), "untouched\n")
        self.assertEqual((old_source / "amdgpu.ko").read_text(), "old untrusted module\n")
        self.assertIn("new module", (self.root / "installed.ko").read_text())

    def test_build_failure_cleans_workspace_and_does_not_install(self):
        result = self.lifecycle(MAKE_MODE="fail")
        self.assertNotEqual(result.returncode, 0)
        workspace = Path((self.root / "workspaces").read_text().splitlines()[0])
        self.assertFalse(workspace.exists())
        self.assertFalse((self.root / "installed.ko").exists())

    def test_successful_build_stdout_is_exactly_the_module_path(self):
        result = self.shell(
            '''
MODSRC="$TEST_ROOT/source"
MODDIR="$TEST_ROOT/kernel"
built="$(build_module)"
[ -f "$built" ] || exit 97
printf '%s\\n' "$built"
'''
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, str(self.amdgpu / "amdgpu.ko") + "\n")
        self.assertIn("compiler output", result.stderr)

    def test_failed_make_cannot_accept_an_old_module_in_conditional_substitution(self):
        module = self.amdgpu / "amdgpu.ko"
        module.write_text("bc250_cc_write_mode\nstale module\n")
        result = self.shell(
            '''
MODSRC="$TEST_ROOT/source"
MODDIR="$TEST_ROOT/kernel"
# Both command substitution and the conditional suppress ordinary errexit.
if built="$(build_module)"; then
    printf 'incorrectly accepted %s\\n' "$built"
    exit 98
fi
[ -z "$built" ]
[ ! -e "$MODSRC/drivers/gpu/drm/amd/amdgpu/amdgpu.ko" ]
''',
            MAKE_MODE="fail",
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, "")
        self.assertFalse(module.exists())

    def test_make_failure_is_rejected_even_when_it_produces_a_module(self):
        result = self.shell(
            '''
MODSRC="$TEST_ROOT/source"
MODDIR="$TEST_ROOT/kernel"
if built="$(build_module)"; then exit 98; fi
[ -z "$built" ]
''',
            MAKE_MODE="fail-with-output",
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, "")
        self.assertTrue((self.amdgpu / "amdgpu.ko").is_file())

    def test_successful_make_without_new_output_cannot_accept_an_old_module(self):
        (self.amdgpu / "amdgpu.ko").write_text("bc250_cc_write_mode\nstale module\n")
        result = self.shell(
            '''
MODSRC="$TEST_ROOT/source"
MODDIR="$TEST_ROOT/kernel"
if built="$(build_module)"; then exit 98; fi
[ -z "$built" ]
''',
            MAKE_MODE="no-output",
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, "")

    def test_partial_extraction_failure_never_accepts_old_or_partial_source(self):
        # Simulate a tar that writes a plausible file and still fails (e.g. a
        # damaged archive). A prior source is also present in the workspace.
        self.command(
            "tar",
            '''#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
    if [ "$1" = -C ]; then target="$2"; break; fi
    shift
done
mkdir -p "$target/drivers/gpu/drm/amd/amdgpu"
printf 'partial source\\n' > "$target/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c"
exit 2
''',
        )
        result = self.shell(
            '''
BUILDDIR="$(mktemp -d "$TMPDIR/extract.XXXXXXXX")"
trap 'rm -rf -- "$BUILDDIR"' EXIT
mkdir -p "$BUILDDIR/src/drivers/gpu/drm/amd/amdgpu"
printf old > "$BUILDDIR/src/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c"
MODSRC="$BUILDDIR/src"
(extract_source "$SOURCE_PACKAGE")
printf 'extraction incorrectly accepted\\n'
'''
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(list(self.tmp.iterdir()), [])
        lifecycle = self.lifecycle()
        self.assertNotEqual(lifecycle.returncode, 0)
        workspace = Path((self.root / "workspaces").read_text().splitlines()[0])
        self.assertFalse(workspace.exists())
        self.assertFalse((self.root / "installed.ko").exists())

    def test_help_and_status_do_not_allocate_a_workspace(self):
        self.command("mktemp", "#!/usr/bin/env bash\n: > \"$TEST_ROOT/unexpected-mktemp\"\nexit 99\n")
        for name in ("lspci", "modinfo", "dmesg"):
            self.command(name, "#!/usr/bin/env bash\nexit 1\n")
        for command in ("--help", "status"):
            result = self.shell('CONF40="$TEST_ROOT/nonexistent.conf"\nmain "$CHECK_COMMAND"', CHECK_COMMAND=command)
            self.assert_success(result)
        self.assertFalse((self.root / "unexpected-mktemp").exists())
        self.assertEqual(list(self.tmp.iterdir()), [])


if __name__ == "__main__":
    unittest.main()

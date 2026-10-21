# Quickstart

This page is the user path for a fresh BC-250 system.

## 1. Check The System

```bash
./scripts/bc250-doctor.sh
```

If the doctor reports that mode7 is missing, build and install the patched
module:

```bash
sudo ./scripts/bc250-enable-40cu.sh build
sudo reboot
```

Packaged kernel sources are extracted into a fresh private build directory,
which is removed when the build exits. Extraction or compilation failure stops
installation; an old module is never accepted as a successful new build. Build
logs go to stderr, separately from the resulting module path.

Existing source trees under `/usr/src` are still administrator-trusted inputs
and are patched and built in place. Use only trusted kernel sources.

After reboot:

```bash
./scripts/bc250-mode7-mask.sh module-check
./scripts/bc250-mode7-mask.sh status
```

## 2. Validate The Baseline

Run the model-free gate before changing WGP combinations:

```bash
./scripts/bc250-fast-kernel-suite.sh gate
```

If the baseline fails, stop. Fix cooling, clocks, Vulkan access, or the kernel
module before testing extra WGPs.

## 3. Discover Single Extra-WGP Candidates

This command installs a systemd resume service. It applies one extra WGP per
boot, validates it, records a TSV result, then reboots to the next target.

```bash
sudo ./scripts/bc250-wgp-autotest.sh start singles
```

The start command installs a root-owned, per-run script snapshot beneath
`/usr/local/lib/bc250-wgp-autotest`. The resume service and privileged mask helper
use that snapshot, not the original checkout. Editing or moving the checkout
does not change an active run. Snapshots are retained; do not edit one to update
a running queue.

Custom `BC250_AUTOTEST_INSTALL_DIR` and `BC250_AUTOTEST_STATE` paths must be
absolute, root-owned, and not group/world-writable, including every ancestor;
symlink components are rejected. A custom `BC250_MODE7_MASK_SCRIPT` must also be
a trusted standalone script, and a custom `BC250_MODE7_CONF` must have a trusted
parent and, if present, a trusted regular target file.

Custom verifiers can remain in the selected unprivileged run user's environment.
Their build and Vulkan settings are applied only when invoking that user, not
to the root service interpreter. Root verifiers require trusted executable paths
and reject code-search overrides such as `CPATH`, `LD_LIBRARY_PATH`, and
`BC250_VULKAN_PREFIX`; select an unprivileged `BC250_AUTOTEST_USER` when those
settings are needed.

`print-service` is available from an installed snapshot only. Existing active
services from older versions are not rewritten automatically: finish or abort
the old queue using its normal controls before starting a new snapshotted run.

Check progress:

```bash
./scripts/bc250-wgp-autotest.sh status
```

After completion:

```bash
./scripts/bc250-wgp-autotest.sh report
```

## 4. Validate Combinations

Build a CSV from the single-WGP PASS candidates. Example:

```bash
GOOD=0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3
./scripts/bc250-wgp-autotest.sh queue matrix "$GOOD" 1
sudo ./scripts/bc250-wgp-autotest.sh start matrix "$GOOD" 1
```

For six candidates, one matrix pass tests:

```text
36CU: 1 combination
34CU: 6 combinations
32CU: 15 combinations
30CU: 20 combinations
```

## 5. Repeat The Best Target

Repeat the largest PASS target. Example:

```bash
BEST=0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3
sudo ./scripts/bc250-wgp-autotest.sh start repeat "$BEST" 10
```

Install the largest PASS target from the current result file:

```bash
sudo ./scripts/bc250-wgp-autotest.sh install-recommended
sudo reboot
```

## 6. Confirm The Installed Configuration

```bash
./scripts/bc250-mode7-mask.sh status
./scripts/bc250-fast-kernel-suite.sh gate
./scripts/bc250-fast-kernel-suite.sh quant-matmul --rows 128 --cols 128 --k 1024 --passes 4
```

Use the largest CU count that repeat-passes. A larger set that sometimes fails
is not a useful compute configuration.

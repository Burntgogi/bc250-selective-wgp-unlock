# BC-250 Selective WGP Unlock Workflow

This workflow helps BC-250 users enable only the extra WGPs that pass repeatable
compute validation. It is designed for script-only operation across reboots.

## Concepts

The stock BC-250 exposes 24 CUs. The extra selectable WGPs are:

```text
0.0.3 0.0.4 0.1.3 0.1.4 1.0.3 1.0.4 1.1.3 1.1.4
```

Each extra WGP represents 2 CUs. A mode7 mask keeps the stock WGPs enabled and
selectively disables extra WGPs through coherent CC, SPI, and RLC masks. This is
different from the original full-40CU mode, because the driver and dispatch
masks are kept in agreement for every tested subset.

## What Changed From The Original Unlock Flow

The original unlock flow was built around full 40CU mode:

```text
options amdgpu bc250_cc_write_mode=3
```

That is useful for boards where all extra WGPs are stable, but it does not help
when only some extra WGPs are usable. The selective workflow adds:

```text
bc250_cc_write_mode=7
```

Mode7 reads `disable_cu=SE.SH.WGP,...` and writes matching CC, SPI, and RLC masks
for each shader array. This avoids configurations where the driver reports one
CU layout while dispatch or power masks use another layout.

The build patch and default build script were updated so new modules advertise:

```text
7=coherent-disable-cus
```

The default build script was also tightened so it inserts the patch into the
real `gfx_v10_0_get_cu_info()` body, not a forward declaration followed by an
unrelated `mutex_lock`.

New distribution scripts:

```text
scripts/bc250-mode7-mask.sh          plan/install mode7 masks
scripts/bc250-wgp-autotest.sh        reboot-resuming WGP queue runner
scripts/bc250-fast-kernel-suite.sh   model-free compute validation profiles
scripts/bc250-quant-matmul-verify.sh packed q4-style matmul verifier
```

## Required Patch Behavior

Your installed `amdgpu` module must expose:

```text
bc250_cc_write_mode=7
```

Mode7 must translate `disable_cu=SE.SH.WGP,...` for WGP 3/4 into matching:

```text
CC_GC_SHADER_ARRAY_CONFIG       inactive extra WGP bits
SPI_PG_ENABLE_STATIC_WGP_MASK   active WGP mask
RLC_PG_ALWAYS_ON_WGP_MASK       active WGP mask
```

Check support:

```bash
./scripts/bc250-mode7-mask.sh module-check
```

## Fast Model-Free Validation

Use compute tests before any model or application workload. The default gate is
chosen to pass a stock 24CU baseline while still exercising large integer, FP32,
bitwise, and LDS workloads:

```bash
./scripts/bc250-fast-kernel-suite.sh gate
```

The quantized matrix multiply verifier adds a packed q4-style matmul pattern:

```bash
./scripts/bc250-fast-kernel-suite.sh quant-matmul --rows 128 --cols 128 --k 1024 --passes 4
```

For longer validation:

```bash
./scripts/bc250-fast-kernel-suite.sh stress
```

## Manual Mask Planning

Plan a known active set without installing it:

```bash
./scripts/bc250-mode7-mask.sh plan-extra-set 0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3
```

Expected output includes:

```text
disabled_extra_wgps=0.0.3,1.1.4
expected_num_cu=36
options amdgpu bc250_cc_write_mode=7 disable_cu=0.0.3,1.1.4
```

Install that mask:

```bash
sudo ./scripts/bc250-mode7-mask.sh apply-extra-set 0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3
sudo reboot
```

Return to the 24CU mode7 baseline:

```bash
sudo ./scripts/bc250-mode7-mask.sh baseline
sudo reboot
```

Remove the mode7 config entirely:

```bash
sudo ./scripts/bc250-mode7-mask.sh disable
sudo reboot
```

## Reboot-Resuming Autotest

The autotest installs a systemd service, applies one WGP set per boot, runs the
model-free verifier, records a TSV result, then reboots into the next target.

Single extra-WGP isolation:

```bash
sudo ./scripts/bc250-wgp-autotest.sh start singles
```

This tests all eight extra WGPs one at a time. After completion:

```bash
./scripts/bc250-wgp-autotest.sh report
```

Matrix testing from the PASS single-WGP candidates:

```bash
sudo ./scripts/bc250-wgp-autotest.sh start matrix 0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3 1
```

For six candidates, one matrix pass is:

```text
36CU: 1 combination
34CU: 6 combinations
32CU: 15 combinations
30CU: 20 combinations
```

Repeat the best candidate:

```bash
sudo ./scripts/bc250-wgp-autotest.sh start repeat 0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3 10
```

Install the largest PASS target recorded in the current results file:

```bash
sudo ./scripts/bc250-wgp-autotest.sh install-recommended
sudo reboot
```

Abort an active run and return to the 24CU mode7 baseline:

```bash
sudo ./scripts/bc250-wgp-autotest.sh abort
```

## Recommended Decision Rule

Use the largest CU count that passes:

1. Stock 24CU baseline with `bc250-fast-kernel-suite.sh gate`.
2. Single-WGP isolation for all eight extra WGPs.
3. Matrix validation across the PASS single-WGP candidates.
4. Repeat validation of the largest PASS matrix target.
5. Optional long stress with `bc250-fast-kernel-suite.sh stress`.

If a larger set passes once but fails repeat validation, prefer the next smaller
repeat-stable set. A configuration that sometimes corrupts output is not useful
for compute workloads.

Single-WGP failures are not always enough. A WGP can pass in isolation yet fail
under a larger combination, so the workflow deliberately separates:

```text
singles -> candidate discovery
matrix  -> combination validation
repeat  -> stability validation
```

## Example Outcome

One validated 36CU outcome is:

```text
active extra WGPs:   0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3
disabled extra WGPs: 0.0.3,1.1.4
modprobe option:     options amdgpu bc250_cc_write_mode=7 disable_cu=0.0.3,1.1.4
```

Treat this as an example, not a universal mask. Each board must be tested.

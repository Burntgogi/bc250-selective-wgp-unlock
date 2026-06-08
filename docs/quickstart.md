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

# Maintainer Release Checklist

Run this checklist before publishing a release.

## Source Hygiene

```bash
tests/run-release-checks.sh
```

Expected:

```text
tests/run-release-checks.sh exits 0
release scrub prints no local/private matches
```

## Patch Validation

If an unpatched `gfx_v10_0.c` is available:

```bash
BC250_PATCH_BASE_GFX=/path/to/unpatched/gfx_v10_0.c tests/run-release-checks.sh
```

Expected:

```text
kernel patch dry-run succeeds
```

## On-Hardware Smoke Test

```bash
./scripts/bc250-doctor.sh
./scripts/bc250-mode7-mask.sh module-check
./scripts/bc250-mode7-mask.sh status
./scripts/bc250-fast-kernel-suite.sh gate
./scripts/bc250-fast-kernel-suite.sh quant-matmul --rows 64 --cols 64 --k 512 --passes 2
```

Expected:

```text
mode7 is available
Vulkan reports the AMD BC-250 device
compute verifier reports errors=0
quant matmul verifier reports errors=0
```

## User Journey Check

Open README from a clean checkout and verify a new user can answer:

```text
What do I run first?
How do I know mode7 is installed?
How do I test without model files?
How do I start singles?
How do I inspect results?
How do I run matrix and repeat?
How do I abort?
How do I return to stock?
```

If any answer requires reading shell internals, update README or docs.

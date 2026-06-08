# Troubleshooting

## `module-check` says mode7 is missing

The loaded `amdgpu` module was not built with this repository's mode7 patch.

```bash
sudo ./scripts/bc250-enable-40cu.sh build
sudo reboot
```

After reboot:

```bash
./scripts/bc250-mode7-mask.sh module-check
```

## `vulkaninfo` only shows llvmpipe

The user running validation cannot access the AMD render node, or RADV is not
available.

Check:

```bash
ls -l /dev/dri
groups
vulkaninfo --summary
```

The autotest script attempts to enable linger and add the run user to `render`
and `video`, but group membership generally needs a new login session.

## Baseline compute validation fails

Do not continue to extra WGP testing. First verify:

```bash
./scripts/bc250-mode7-mask.sh baseline
sudo reboot
./scripts/bc250-fast-kernel-suite.sh gate
```

If baseline still fails, check clocks, voltage, thermals, Vulkan driver state,
and kernel module installation.

## Autotest is running and you need to stop it

```bash
sudo ./scripts/bc250-wgp-autotest.sh abort
```

This disables the resume service, writes the mode7 24CU baseline, and reboots.

## A WGP passes singles but fails matrix

Treat singles as candidate discovery only. Combination failures are real. Use
the largest matrix PASS target and then repeat-test it.

## A target passes once but fails repeat

Prefer the next smaller repeat-stable target. Intermittent corruption is worse
than fewer stable CUs for compute workloads.

## Return to stock behavior

```bash
sudo ./scripts/bc250-mode7-mask.sh disable
sudo reboot
```

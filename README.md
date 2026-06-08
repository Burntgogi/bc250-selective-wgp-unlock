[한국어](README.ko.md) | [English](README.md)

# BC-250 Selective WGP Unlock

Script-only tooling for testing and enabling stable extra WGPs on AMD BC-250
systems.

The stock BC-250 exposes 24 CUs. The original full unlock path can expose all
40 CUs, but not every board is stable with every harvested WGP enabled. This
repository adds a coherent mode7 masking workflow so users can find bad extra
WGPs and run the largest repeat-stable CU configuration.

## Credits

This project builds on the original public work at
[duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock).
Thanks to duggasco and the original contributors for documenting the BC-250 CU
unlock path and making this follow-up selective WGP workflow possible.

## Start Here

Run the non-destructive doctor first:

```bash
./scripts/bc250-doctor.sh
```

Then follow the guided workflow:

```bash
less docs/quickstart.md
```

The short path is:

```bash
# 1. Build a patched amdgpu if mode7 is not already available.
sudo ./scripts/bc250-enable-40cu.sh build
sudo reboot

# 2. Verify the current configuration without model files.
./scripts/bc250-fast-kernel-suite.sh gate

# 3. Test each extra WGP across reboots.
sudo ./scripts/bc250-wgp-autotest.sh start singles

# 4. Inspect results after the run returns to baseline.
./scripts/bc250-wgp-autotest.sh report

# 5. Test combinations from the single-WGP PASS candidates.
sudo ./scripts/bc250-wgp-autotest.sh start matrix 0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3 1

# 6. Repeat-test the best target, then install the largest PASS target.
sudo ./scripts/bc250-wgp-autotest.sh start repeat 0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3 10
sudo ./scripts/bc250-wgp-autotest.sh install-recommended
sudo reboot
```

The WGP list above is an example. Use your own PASS candidates.

## What This Repository Provides

- `patch/bc250-40cu-amdgpu.patch`: amdgpu patch with `bc250_cc_write_mode=7`
- `scripts/bc250-enable-40cu.sh`: build/install helper for the patched module
- `scripts/bc250-mode7-mask.sh`: plan and install coherent mode7 masks
- `scripts/bc250-wgp-autotest.sh`: reboot-resuming singles, matrix, repeat runner
- `scripts/bc250-fast-kernel-suite.sh`: model-free compute validation profiles
- `scripts/bc250-quant-matmul-verify.sh`: packed q4-style matrix multiply verifier
- `scripts/bc250-compute-verify.sh`: heavy Vulkan integer/FP/LDS verifier
- `scripts/bc250-doctor.sh`: onboarding and readiness checker

## Safety Model

- The patch is gated to BC-250 PCI device ID `0x13FE`.
- Default module parameter mode is off.
- `bc250_cc_write_mode=7` keeps CC, SPI, and RLC masks coherent.
- `baseline` returns to a mode7 24CU configuration.
- Removing the modprobe config and rebooting returns to stock behavior.

Abort an active autotest and return to baseline:

```bash
sudo ./scripts/bc250-wgp-autotest.sh abort
```

Remove the BC-250 modprobe config:

```bash
sudo ./scripts/bc250-mode7-mask.sh disable
sudo reboot
```

## Documentation

- [Quickstart](docs/quickstart.md)
- [Selective WGP workflow](docs/selective-wgp-unlock.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Maintainer release checklist](docs/maintainer-release-checklist.md)

## Requirements

- Linux with BC-250 hardware
- Kernel headers/source matching the running kernel
- `gcc`, `make`, `zstd`, `patch`
- Vulkan runtime, RADV, `vulkaninfo`
- `glslangValidator` for the compute verifiers

## License

Original contributions are MIT-licensed. See [LICENSE](LICENSE).

Some files are derived from the original BC-250 unlock work and retain separate
provenance or license notes. See [NOTICE.md](NOTICE.md).

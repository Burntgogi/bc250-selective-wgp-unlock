# Notices And Provenance

This repository is a follow-up workflow built on public BC-250 unlock research.

## Original Project

The original public project is:

```text
https://github.com/duggasco/bc250-40cu-unlock
```

Thanks to duggasco and the original contributors for documenting the BC-250
40CU unlock path, including the CC/SPI/RLC register behavior that this project
builds on.

## License Boundaries

Original contributions are MIT-licensed. See `LICENSE`.

The build helper `scripts/bc250-enable-40cu.sh` is derived from the original
BC-250 build helper. The local upstream copy carried a GPL-2.0 notice, so this
file is kept under GPL-2.0-only unless the upstream authors grant different
terms. See `LICENSES/GPL-2.0-only.txt`.

The kernel patch `patch/bc250-40cu-amdgpu.patch` is a downstream patch derived
from the original BC-250 40CU patch and modified for coherent mode7 WGP masks.
The patch header records the original project with `Based-on` and signs off the
downstream modifications separately.

New scripts, docs, tests, CI, and release metadata in this repository are
intended to be MIT-licensed unless a file states otherwise.

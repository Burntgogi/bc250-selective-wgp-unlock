# Security Policy

## Supported Branch

Security fixes are handled on `main`.

## Reporting Security Issues

Do not publish exploit details in public issues. Report security-sensitive
problems to the repository owner first.

## Write Access Policy

Only the repository owner is allowed to push or merge changes. External users
may read, fork, and propose issues, but direct modification of this repository
is not granted.

## Release Checks

Every release should pass:

```bash
tests/run-release-checks.sh
```

On BC-250 hardware, also run:

```bash
./scripts/bc250-doctor.sh
./scripts/bc250-fast-kernel-suite.sh gate
./scripts/bc250-fast-kernel-suite.sh quant-matmul --rows 64 --cols 64 --k 512 --passes 2
```

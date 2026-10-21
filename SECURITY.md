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

## Privileged Execution

Building and changing masks require trusted kernel sources and an explicitly
authorized administrator invocation. Packaged sources and patch fragments use
fresh private temporary directories; failed extraction or compilation cannot
fall back to a previous build artifact.

Reboot-resuming queues install root-owned script snapshots instead of executing
a mutable checkout on later boots. Installation, state, service, and mask
configuration paths reject unsafe ownership, writable ancestors, and symlinks.
Default verifiers are snapshotted with their helper scripts; custom privileged
helpers must be trusted. User verifier search paths are not placed in the root
service environment. Root verifiers reject persisted code-search overrides.

These checks do not make an untrusted initial checkout or kernel source safe.
Review the code before authorizing its initial privileged execution. Previously
installed services remain unchanged until a new queue is started.

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

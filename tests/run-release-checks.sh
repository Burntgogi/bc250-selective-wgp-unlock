#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/tests/test-release-scrub.sh"
"$ROOT/tests/test-script-contracts.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/drivers/gpu/drm/amd/amdgpu"

if [ -n "${BC250_PATCH_BASE_GFX:-}" ] && [ -f "$BC250_PATCH_BASE_GFX" ]; then
	cp "$BC250_PATCH_BASE_GFX" "$tmpdir/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c"
	patch --dry-run -p1 -d "$tmpdir" < "$ROOT/patch/bc250-40cu-amdgpu.patch" >/dev/null
else
	echo "SKIP: set BC250_PATCH_BASE_GFX=/path/to/unpatched/gfx_v10_0.c to dry-run kernel patch" >&2
fi

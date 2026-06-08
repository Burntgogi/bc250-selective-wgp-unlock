#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_files=(
	"$ROOT/README.md"
	"$ROOT/README.ko.md"
	"$ROOT/LICENSE"
	"$ROOT/NOTICE.md"
	"$ROOT/SECURITY.md"
	"$ROOT/LICENSES/GPL-2.0-only.txt"
	"$ROOT/.github/CODEOWNERS"
	"$ROOT/.github/workflows/release-checks.yml"
	"$ROOT/patch/bc250-40cu-amdgpu.patch"
	"$ROOT/scripts/bc250-doctor.sh"
	"$ROOT/scripts/bc250-enable-40cu.sh"
	"$ROOT/scripts/bc250-mode7-mask.sh"
	"$ROOT/scripts/bc250-wgp-autotest.sh"
	"$ROOT/scripts/bc250-fast-kernel-suite.sh"
	"$ROOT/scripts/bc250-quant-matmul-verify.sh"
	"$ROOT/scripts/bc250-compute-verify.sh"
	"$ROOT/docs/quickstart.md"
	"$ROOT/docs/selective-wgp-unlock.md"
	"$ROOT/docs/troubleshooting.md"
	"$ROOT/docs/maintainer-release-checklist.md"
)

missing=0
for file in "${required_files[@]}"; do
	if [ ! -f "$file" ]; then
		echo "missing release file: $file" >&2
		missing=1
	fi
done
[ "$missing" = "0" ]

private_user='jmt''ai5'
private_home='/ho''me/jmt''ai5'
model_a='gem''ma'
model_b='qw''en'
model_org='uns''loth'
model_runtime='lla''ma'
run_stamp='2026''06'
old_state='/var/lib/bc250-extra-auto''test'
old_helper='bc250-selective-mask-''test'
forbidden="${private_user}|${private_home}|${model_a}|${model_b}|${model_org}|${model_runtime}|${run_stamp}|${old_state}|${old_helper}"

if grep -REn "$forbidden" \
	"$ROOT/README.md" "$ROOT/README.ko.md" "$ROOT/SECURITY.md" "$ROOT/.github" "$ROOT/docs" "$ROOT/scripts" "$ROOT/patch"; then
	echo "release tree contains local paths, private run artifacts, or model-specific dependencies" >&2
	exit 1
fi

grep -Fq '[한국어](README.ko.md)' "$ROOT/README.md"
grep -Fq '[English](README.md)' "$ROOT/README.ko.md"
head -1 "$ROOT/README.md" | grep -Fq '[한국어](README.ko.md)'
head -1 "$ROOT/README.ko.md" | grep -Fq '[English](README.md)'
grep -Fq 'https://github.com/duggasco/bc250-40cu-unlock' "$ROOT/README.md"
grep -Fq 'https://github.com/duggasco/bc250-40cu-unlock' "$ROOT/README.ko.md"
grep -Fq 'Thanks' "$ROOT/README.md"
grep -Fq '감사' "$ROOT/README.ko.md"
grep -Fq './scripts/bc250-doctor.sh' "$ROOT/README.md"
grep -Fq './scripts/bc250-doctor.sh' "$ROOT/README.ko.md"
grep -Fq 'sudo ./scripts/bc250-wgp-autotest.sh start singles' "$ROOT/README.md"
grep -Fq 'sudo ./scripts/bc250-wgp-autotest.sh start singles' "$ROOT/README.ko.md"
grep -Fq 'sudo ./scripts/bc250-wgp-autotest.sh start matrix' "$ROOT/docs/quickstart.md"
grep -Fq 'MIT License' "$ROOT/LICENSE"
grep -Fq 'MIT' "$ROOT/README.md"
grep -Fq 'MIT' "$ROOT/README.ko.md"
grep -Fq 'Original contributions are MIT-licensed.' "$ROOT/NOTICE.md"
grep -Fq 'SPDX-License-Identifier: GPL-2.0-only' "$ROOT/scripts/bc250-enable-40cu.sh"
grep -Fq 'Based-on: https://github.com/duggasco/bc250-40cu-unlock' "$ROOT/patch/bc250-40cu-amdgpu.patch"
grep -Fq 'Signed-off-by: Burntgogi <224273819+Burntgogi@users.noreply.github.com>' "$ROOT/patch/bc250-40cu-amdgpu.patch"
if grep -Eq '^From: duggasco|^Signed-off-by: duggasco' "$ROOT/patch/bc250-40cu-amdgpu.patch"; then
	echo "modified patch must not present duggasco as the author/sign-off for downstream changes" >&2
	exit 1
fi
grep -Fq '* @Burntgogi' "$ROOT/.github/CODEOWNERS"
grep -Fq 'Only the repository owner is allowed to push or merge changes.' "$ROOT/SECURITY.md"
grep -Fq 'tests/run-release-checks.sh' "$ROOT/.github/workflows/release-checks.yml"

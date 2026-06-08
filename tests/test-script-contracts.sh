#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOOD="0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3"

bash -n "$ROOT"/scripts/*.sh

plan="$("$ROOT/scripts/bc250-mode7-mask.sh" plan-extra-set "$GOOD")"
grep -Fq "disabled_extra_wgps=0.0.3,1.1.4" <<<"$plan"
grep -Fq "expected_num_cu=36" <<<"$plan"
grep -Fq "options amdgpu bc250_cc_write_mode=7 disable_cu=0.0.3,1.1.4" <<<"$plan"

queue="$("$ROOT/scripts/bc250-wgp-autotest.sh" queue matrix "$GOOD" 1)"
target_count="$(awk 'NR > 1 { count++ } END { print count + 0 }' <<<"$queue")"
[ "$target_count" = "42" ] || {
	echo "expected 42 matrix targets, got $target_count" >&2
	exit 1
}
awk 'NR > 1 && $3 == 36 { c36++ } NR > 1 && $3 == 34 { c34++ } NR > 1 && $3 == 32 { c32++ } NR > 1 && $3 == 30 { c30++ } END { exit !(c36 == 1 && c34 == 6 && c32 == 15 && c30 == 20) }' <<<"$queue"

for script in \
	"$ROOT/scripts/bc250-doctor.sh" \
	"$ROOT/scripts/bc250-mode7-mask.sh" \
	"$ROOT/scripts/bc250-wgp-autotest.sh" \
	"$ROOT/scripts/bc250-fast-kernel-suite.sh" \
	"$ROOT/scripts/bc250-quant-matmul-verify.sh" \
	"$ROOT/scripts/bc250-compute-verify.sh"; do
	help_text="$("$script" --help)"
	host_path_pattern='/ho''me/|/tm''p/'
	if grep -Eq "$host_path_pattern" <<<"$help_text"; then
		echo "help output should not expose host-specific paths: $script" >&2
		exit 1
	fi
done

enable_help="$("$ROOT/scripts/bc250-enable-40cu.sh")"
host_path_pattern='/ho''me/|/tm''p/'
if grep -Eq "$host_path_pattern" <<<"$enable_help"; then
	echo "enable help output should not expose host-specific paths" >&2
	exit 1
fi

#!/usr/bin/env bash
# Recommendation fixtures never read live state or install a GPU mask.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
failures=0

fixture() {
	local index target rest targets="" count=0
	printf 'index\ttarget\texpected_num_cu\tactual_num_cu\tverify_rc\tresult\tstarted_at\tended_at\tlog\n' >"$tmpdir/results.tsv"
	printf '%b' "$1" >>"$tmpdir/results.tsv"
	while IFS=$'\t' read -r index target rest; do
		[ "$index" != index ] || continue
		targets+="$target "
		count=$((count + 1))
	done <"$tmpdir/results.tsv"
	printf 'PHASE=done\nINDEX=%q\nTARGETS=%q\n' "$count" "${targets% }" >"$tmpdir/state"
}

check_case() {
	local name="$1" expected="$2" cu="$3" output rc report
	set +e
	output="$(bash --noprofile --norc -s -- "$ROOT" "$tmpdir/results.tsv" 2>&1 <<'BASH'
set -euo pipefail
export BC250_AUTOTEST_USER=fixture
source "$1/scripts/bc250-wgp-autotest.sh"
RESULTS_FILE="$2"
STATE_FILE="${RESULTS_FILE%/*}/state"
need_root() { :; }
with_lock() { printf 'MOCK_LOCK\n'; }
trusted_file() { :; }
trusted_mask_config() { :; }
record_mask() { printf 'MOCK_APPLY %s\n' "$*"; }
MASK=record_mask
install_recommended
BASH
)"
	rc=$?
	set -e
	report="$(bash --noprofile --norc -s -- "$ROOT" "$tmpdir" <<'BASH'
set -euo pipefail
export BC250_AUTOTEST_USER=fixture BC250_AUTOTEST_STATE="$2"
source "$1/scripts/bc250-wgp-autotest.sh"
trusted_file() { :; }
show_report
BASH
)"
	if { [ -n "$expected" ] && [ "$rc" -eq 0 ] && grep -Fxq "MOCK_APPLY apply-extra-set $expected" <<<"$output"; } ||
		{ [ -z "$expected" ] && [ "$rc" -ne 0 ] && [[ "$output" != *MOCK_APPLY* ]]; }; then
		if grep -Fxq "recommended_active_extra_wgps=${expected:-none}" <<<"$report" &&
			grep -Fxq "recommended_num_cu=$cu" <<<"$report"; then
			printf 'PASS %s\n' "$name"
			return
		fi
	fi
	printf 'FAIL %s (rc=%s)\n%s\n%s\n' "$name" "$rc" "$output" "$report" >&2
	failures=$((failures + 1))
}

pass='0\t0.0.4,0.1.4\t28\t28\t0\tPASS\tfixture\tfixture\tfixture\n'
fail='1\t0.0.4,0.1.4\t28\t28\t1\tFAIL\tfixture\tfixture\tfixture\n'
smaller='2\t0.0.4\t26\t26\t0\tPASS\tfixture\tfixture\tfixture\n'
fixture "$pass$fail"
check_case 'PASS followed by FAIL is not recommended' '' 0
fixture "$fail$pass"
check_case 'FAIL followed by PASS is not recommended' '' 0
fixture "$pass$fail$smaller$smaller"
check_case 'a smaller repeat-stable target is preferred' '0.0.4' 26
fixture "$pass$pass$smaller"
check_case 'all passing repeats keep the largest target' '0.0.4,0.1.4' 28
fixture "$fail"
check_case 'failed-only targets are rejected' '' 0
fixture ''
check_case 'empty results are rejected' '' 0
fixture '0\tnone\t24\t24\t0\tPASS\tfixture\tfixture\tfixture\n'
check_case 'baseline does not become an extra-WGP recommendation' '' 0
fixture "$smaller"'3\t0.1.4\t26\t26\t0\tPASS\tfixture\tfixture\tfixture\n'
check_case 'equal CU targets preserve first-tested preference' '0.0.4' 26
for phase in booting running; do
	fixture "$pass"
	printf 'PHASE=%q\nINDEX=1\nTARGETS=%q\n' "$phase" '0.0.4,0.1.4 0.0.4,0.1.4' >"$tmpdir/state"
	check_case "$phase repeat cannot install its first PASS" '' 0
done
fixture "$pass$pass"
printf 'PHASE=done\nINDEX=1\nTARGETS=%q\n' '0.0.4,0.1.4 0.0.4,0.1.4' >"$tmpdir/state"
check_case 'incomplete queue index cannot recommend a target' '' 0
fixture "$pass"
printf 'PHASE=done\nINDEX=2\nTARGETS=%q\n' '0.0.4,0.1.4 0.0.4,0.1.4' >"$tmpdir/state"
check_case 'missing repeat result cannot recommend a target' '' 0
printf '12 cases, %s failures\n' "$failures"
[ "$failures" -eq 0 ]

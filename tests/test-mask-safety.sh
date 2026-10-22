#!/usr/bin/env bash
# Hardware-free regressions: only temporary files and mocked privileged commands.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
failures=0
checks=0

check() {
	local name="$1"
	shift
	checks=$((checks + 1))
	if "$@"; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name" >&2
		failures=$((failures + 1))
	fi
}

# Run each caller in its own shell so errexit is not disabled by the test's
# assertion context. Mask paths and every privileged operation are mocked.
for updater in update-initramfs dracut; do
	for action in install disable install-if disable-if; do
		for updater_rc in 0 42; do
			set +e
			output="$(bash --noprofile --norc -s -- "$ROOT" "$tmpdir" "$updater" "$action" "$updater_rc" 2>&1 <<'BASH'
set -euo pipefail
root="$1"
fixture="$2"
updater="$3"
action="$4"
updater_rc="$5"
export BC250_MODE7_CONF="$fixture/mode7.conf"
source "$root/scripts/bc250-mode7-mask.sh" --help >/dev/null
need_root() { :; }
uname() { printf 'fixture-kernel\n'; }
install() { cp -- "$3" "$4"; }
command() {
	if [ "${1:-}" = -v ] && { [ "${2:-}" = update-initramfs ] || [ "${2:-}" = dracut ]; }; then
		[ "$2" = "$updater" ]
	else
		builtin command "$@"
	fi
}
update-initramfs() { printf 'mock update-initramfs %s\n' "$*"; return "$updater_rc"; }
dracut() { printf 'mock dracut %s\n' "$*"; return "$updater_rc"; }
printf 'old fixture config\n' >"$CONF"
case "$action" in
	install) install_active 0.0.4 ;;
	disable) disable_config ;;
	install-if) if install_active 0.0.4; then :; else exit "$?"; fi ;;
	disable-if) if disable_config; then :; else exit "$?"; fi ;;
esac
printf 'CALLER_CONTINUED\n'
BASH
)"
			rc=$?
			set -e
			check "$updater $action propagates status $updater_rc" test "$rc" -eq "$updater_rc"
			if [ "$updater_rc" -ne 0 ]; then
				check "$updater $action does not report success after failure" test "${output#*config=}" = "$output"
				check "$updater $action stops caller after failure" test "${output#*CALLER_CONTINUED}" = "$output"
			else
				check "$updater $action allows successful caller" test "${output#*CALLER_CONTINUED}" != "$output"
			fi
		done
	done
done

# Exercise the real autotest handoff without any actual reboot or state access.
for action in apply_current_and_reboot finish_and_return_baseline abort_run; do
	set +e
	output="$(bash --noprofile --norc -s -- "$ROOT" "$action" 2>&1 <<'BASH'
set -euo pipefail
export BC250_AUTOTEST_USER=fixture
source "$1/scripts/bc250-wgp-autotest.sh"
need_root() { :; }
trusted_mask_config() { :; }
with_lock() { :; }
load_state() { :; }
save_state() { :; }
disable_service() { :; }
target_at_index() { printf '0.0.4\n'; }
reject_mask() { return 42; }
MASK=reject_mask
sync() { printf 'UNEXPECTED_SYNC\n'; }
sleep() { printf 'UNEXPECTED_SLEEP\n'; }
systemctl() { printf 'UNEXPECTED_REBOOT\n'; }
"$2"
BASH
)"
	rc=$?
	set -e
	check "$action propagates mask failure" test "$rc" -eq 42
	check "$action stops before reboot preparation" test "${output#*UNEXPECTED_}" = "$output"
done

printf '%s checks, %s failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]

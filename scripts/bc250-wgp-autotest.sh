#!/usr/bin/env bash
# Reboot-resuming WGP combination tester for BC-250 mode7 masks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(readlink -f "$0")"
MASK="${BC250_MODE7_MASK_SCRIPT:-$SCRIPT_DIR/bc250-mode7-mask.sh}"
VERIFY_BIN="${BC250_AUTOTEST_VERIFY_BIN:-$SCRIPT_DIR/bc250-fast-kernel-suite.sh}"
VERIFY_MODE="${BC250_AUTOTEST_VERIFY_MODE:-gate}"
STATE_DIR="${BC250_AUTOTEST_STATE:-/var/lib/bc250-wgp-autotest}"
LOG_DIR="$STATE_DIR/logs"
STATE_FILE="$STATE_DIR/state"
RESULTS_FILE="$STATE_DIR/results.tsv"
LOCK_FILE="$STATE_DIR/lock"
SERVICE_NAME="${BC250_AUTOTEST_SERVICE:-bc250-wgp-autotest.service}"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
SINGLE_QUEUE="0.0.3 0.0.4 0.1.3 0.1.4 1.0.3 1.0.4 1.1.3 1.1.4"

PHASE="none"
MODE=""
INDEX=0
TARGETS=""
CURRENT_TARGET=""
RUN_USER="${BC250_AUTOTEST_USER:-${SUDO_USER:-$(id -un)}}"
VERIFY_ARGS=""
LAST_RESULT=""
LAST_LOG=""
LAST_UPDATED=""

usage() {
	cat <<EOF
Usage:
  sudo ./scripts/bc250-wgp-autotest.sh start singles [VERIFY_ARGS...]
  sudo ./scripts/bc250-wgp-autotest.sh start auto [VERIFY_ARGS...]
  sudo ./scripts/bc250-wgp-autotest.sh start matrix GOOD_WGPS_CSV COUNT [VERIFY_ARGS...]
  sudo ./scripts/bc250-wgp-autotest.sh start repeat ACTIVE_WGPS_CSV COUNT [VERIFY_ARGS...]
  sudo ./scripts/bc250-wgp-autotest.sh resume
  sudo ./scripts/bc250-wgp-autotest.sh abort
  sudo ./scripts/bc250-wgp-autotest.sh install-recommended
  ./scripts/bc250-wgp-autotest.sh status
  ./scripts/bc250-wgp-autotest.sh report
  ./scripts/bc250-wgp-autotest.sh queue singles
  ./scripts/bc250-wgp-autotest.sh queue matrix GOOD_WGPS_CSV COUNT
  ./scripts/bc250-wgp-autotest.sh queue repeat ACTIVE_WGPS_CSV COUNT

The default verifier is:
  ./scripts/$(basename "$VERIFY_BIN") $VERIFY_MODE

start auto currently runs the singles queue. Use report and install-recommended
after completion, or run a matrix queue from the PASS single-WGP candidates.
EOF
}

info() {
	printf '[+] %s\n' "$*"
}

warn() {
	printf '[!] %s\n' "$*" >&2
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

need_root() {
	[ "$(id -u)" = "0" ] || die "this command requires root"
}

ensure_state_dir() {
	install -d -m 0755 "$STATE_DIR" "$LOG_DIR"
}

save_state() {
	ensure_state_dir
	LAST_UPDATED="$(date -Iseconds)"
	{
		printf 'PHASE=%q\n' "$PHASE"
		printf 'MODE=%q\n' "$MODE"
		printf 'INDEX=%q\n' "$INDEX"
		printf 'TARGETS=%q\n' "$TARGETS"
		printf 'CURRENT_TARGET=%q\n' "$CURRENT_TARGET"
		printf 'RUN_USER=%q\n' "$RUN_USER"
		printf 'VERIFY_ARGS=%q\n' "$VERIFY_ARGS"
		printf 'LAST_RESULT=%q\n' "$LAST_RESULT"
		printf 'LAST_LOG=%q\n' "$LAST_LOG"
		printf 'LAST_UPDATED=%q\n' "$LAST_UPDATED"
	} >"$STATE_FILE.tmp"
	chmod 0644 "$STATE_FILE.tmp"
	mv "$STATE_FILE.tmp" "$STATE_FILE"
}

load_state() {
	if [ -f "$STATE_FILE" ]; then
		# shellcheck disable=SC1090
		. "$STATE_FILE"
	fi
}

with_lock() {
	ensure_state_dir
	exec 9>"$LOCK_FILE"
	flock -n 9 || die "another autotest command is running"
}

validate_extra() {
	local item="$1"
	[[ "$item" =~ ^[0-1]\.[0-1]\.[3-4]$ ]] || die "invalid extra WGP: $item"
}

validate_csv_or_none() {
	local csv="${1:-none}"
	local -a items=()
	local item

	[ "$csv" != "none" ] || return 0
	[ -n "$csv" ] || return 0
	IFS=',' read -ra items <<<"$csv"
	for item in "${items[@]}"; do
		item="${item//[[:space:]]/}"
		validate_extra "$item"
	done
}

csv_to_array() {
	local csv="${1:-none}"
	local -n out_ref="$2"
	local item

	out_ref=()
	[ "$csv" != "none" ] || return 0
	IFS=',' read -ra out_ref <<<"$csv"
	for item in "${!out_ref[@]}"; do
		out_ref[$item]="${out_ref[$item]//[[:space:]]/}"
		[ -n "${out_ref[$item]}" ] || die "empty WGP entry in CSV: $csv"
		validate_extra "${out_ref[$item]}"
	done
}

join_csv() {
	local IFS=,
	echo "$*"
}

emit_combinations() {
	local src_name="$1"
	local out_name="$2"
	local need="$3"
	local start="$4"
	local prefix="${5:-}"
	local -n src_ref="$src_name"
	local -n out_ref="$out_name"
	local i next

	if [ "$need" -eq 0 ]; then
		out_ref+=("${prefix#,}")
		return 0
	fi
	for ((i = start; i <= ${#src_ref[@]} - need; i++)); do
		next="${prefix},${src_ref[$i]}"
		emit_combinations "$src_name" "$out_name" "$((need - 1))" "$((i + 1))" "$next"
	done
}

matrix_queue() {
	local good_csv="${1:-}"
	local count="${2:-}"
	local -a extras=()
	local -a once=()
	local -a all=()
	local size repeat

	[ -n "$good_csv" ] || die "missing GOOD_WGPS_CSV"
	[ -n "$count" ] || die "missing matrix repeat count"
	[[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ] || die "matrix count must be a positive integer"
	csv_to_array "$good_csv" extras
	[ "${#extras[@]}" -ge 3 ] || die "matrix requires at least three good WGPs"

	for size in 6 5 4 3; do
		if [ "${#extras[@]}" -ge "$size" ]; then
			emit_combinations extras once "$size" 0
		fi
	done
	for repeat in $(seq 1 "$count"); do
		all+=("${once[@]}")
	done
	echo "${all[*]}"
}

repeat_queue() {
	local target="${1:-}"
	local count="${2:-}"
	local -a out=()
	local i

	validate_csv_or_none "$target"
	[[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ] || die "repeat count must be a positive integer"
	for i in $(seq 1 "$count"); do
		out+=("$target")
	done
	echo "${out[*]}"
}

target_count() {
	local -a targets=()
	read -ra targets <<<"$TARGETS"
	echo "${#targets[@]}"
}

target_at_index() {
	local idx="$1"
	local -a targets=()
	read -ra targets <<<"$TARGETS"
	[ "$idx" -ge 0 ] && [ "$idx" -lt "${#targets[@]}" ] || return 1
	echo "${targets[$idx]}"
}

extra_count() {
	local target="${1:-none}"
	local -a extras=()
	csv_to_array "$target" extras
	echo "${#extras[@]}"
}

expected_num_cu_for_target() {
	echo $((24 + 2 * $(extra_count "${1:-none}")))
}

current_num_cu() {
	RADV_DEBUG=info vulkaninfo --summary 2>/dev/null |
		awk -F= '/num_cu =/ { gsub(/[ \t]/, "", $2); print $2; exit }'
}

wait_vulkan_ready() {
	local expected="$1"
	local timeout_s="${BC250_AUTOTEST_VULKAN_TIMEOUT:-180}"
	local deadline=$((SECONDS + timeout_s))
	local seen=""

	while [ "$SECONDS" -lt "$deadline" ]; do
		seen="$(current_num_cu || true)"
		if [ "$seen" = "$expected" ]; then
			info "Vulkan reports expected num_cu=$seen"
			return 0
		fi
		sleep 3
	done
	warn "Vulkan did not reach expected num_cu=$expected; last_seen=${seen:-none}"
	return 1
}

print_service() {
	cat <<EOF
[Unit]
Description=BC-250 WGP autotest resume
After=multi-user.target systemd-user-sessions.service
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=$SELF resume
TimeoutStartSec=30min
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
}

ensure_user_access() {
	local group

	id "$RUN_USER" >/dev/null 2>&1 || die "run user does not exist: $RUN_USER"
	if command -v loginctl >/dev/null 2>&1; then
		loginctl enable-linger "$RUN_USER" >/dev/null 2>&1 || warn "could not enable linger for $RUN_USER"
	fi
	for group in render video; do
		if getent group "$group" >/dev/null 2>&1 && ! id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx "$group"; then
			usermod -aG "$group" "$RUN_USER" || warn "could not add $RUN_USER to $group"
		fi
	done
}

install_service() {
	need_root
	ensure_user_access
	print_service >"$SERVICE_FILE"
	chmod 0644 "$SERVICE_FILE"
	systemctl daemon-reload
	systemctl enable "$SERVICE_NAME" >/dev/null
}

disable_service() {
	systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
	systemctl daemon-reload || true
}

run_as_user_logged() {
	local log="$1"
	shift
	local uid home rc

	uid="$(id -u "$RUN_USER")"
	home="$(getent passwd "$RUN_USER" | awk -F: '{print $6}')"
	{
		echo "started_at=$(date -Iseconds)"
		echo "run_user=$RUN_USER"
		echo "command=$*"
		echo
	} >"$log"

	if [ "$RUN_USER" = "root" ]; then
		if "$@" >>"$log" 2>&1; then
			rc=0
		else
			rc=$?
		fi
	else
		if runuser -u "$RUN_USER" -- env \
			HOME="$home" \
			XDG_RUNTIME_DIR="/run/user/$uid" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
			"$@" >>"$log" 2>&1; then
			rc=0
		else
			rc=$?
		fi
	fi

	{
		echo
		echo "ended_at=$(date -Iseconds)"
		echo "rc=$rc"
	} >>"$log"
	return "$rc"
}

append_result() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$RESULTS_FILE"
}

start_queue() {
	local mode="$1"
	local queue="$2"
	local verify_args="${3:-}"

	need_root
	with_lock
	load_state
	[ "$PHASE" != "booting" ] && [ "$PHASE" != "running" ] || die "autotest is already active"
	[ -x "$MASK" ] || die "missing mask script: $MASK"
	[ -x "$VERIFY_BIN" ] || die "missing verifier: $VERIFY_BIN"
	"$MASK" module-check >/dev/null || die "installed amdgpu module does not support bc250_cc_write_mode=7"

	ensure_state_dir
	if [ -s "$RESULTS_FILE" ]; then
		cp -a "$RESULTS_FILE" "$RESULTS_FILE.bak-$(date +%Y%m%d-%H%M%S)"
	fi
	printf 'index\ttarget\texpected_num_cu\tactual_num_cu\tverify_rc\tresult\tstarted_at\tended_at\tlog\n' >"$RESULTS_FILE"
	chmod 0644 "$RESULTS_FILE"

	PHASE="booting"
	MODE="$mode"
	INDEX=0
	TARGETS="$queue"
	VERIFY_ARGS="$verify_args"
	CURRENT_TARGET="$(target_at_index "$INDEX")"
	LAST_RESULT=""
	LAST_LOG=""
	save_state
	install_service
	apply_current_and_reboot
}

apply_current_and_reboot() {
	need_root
	CURRENT_TARGET="$(target_at_index "$INDEX")" || finish_and_return_baseline
	PHASE="booting"
	save_state
	info "Applying active extra WGPs: $CURRENT_TARGET"
	"$MASK" apply-extra-set "$CURRENT_TARGET"
	sync
	sleep "${BC250_AUTOTEST_REBOOT_DELAY:-3}"
	systemctl reboot
}

finish_and_return_baseline() {
	need_root
	PHASE="done"
	CURRENT_TARGET=""
	save_state
	disable_service
	info "Queue complete. Returning to 24CU mode7 baseline."
	"$MASK" baseline
	sync
	sleep "${BC250_AUTOTEST_REBOOT_DELAY:-3}"
	systemctl reboot
}

resume_run() {
	need_root
	with_lock
	load_state
	if [ "$PHASE" = "none" ] || [ "$PHASE" = "done" ] || [ "$PHASE" = "aborted" ]; then
		info "No active autotest run: phase=$PHASE"
		return 0
	fi

	local target expected actual stamp safe_target log started ended rc result
	local -a verify_args=()

	target="$(target_at_index "$INDEX")" || finish_and_return_baseline
	CURRENT_TARGET="$target"
	PHASE="running"
	save_state

	sleep "${BC250_AUTOTEST_BOOT_SETTLE:-20}"
	expected="$(expected_num_cu_for_target "$target")"
	wait_vulkan_ready "$expected" || true
	actual="$(current_num_cu || true)"
	actual="${actual:-unknown}"

	stamp="$(date +%Y%m%d-%H%M%S)"
	safe_target="${target//./_}"
	safe_target="${safe_target//,/_}"
	log="$LOG_DIR/${stamp}-idx${INDEX}-${safe_target}.log"
	started="$(date -Iseconds)"

	if [ -n "$VERIFY_ARGS" ]; then
		read -ra verify_args <<<"$VERIFY_ARGS"
	fi

	set +e
	run_as_user_logged "$log" "$VERIFY_BIN" "$VERIFY_MODE" "${verify_args[@]}"
	rc=$?
	set -e

	if [ "$rc" -eq 0 ] && [ "$actual" = "$expected" ]; then
		result="PASS"
	else
		result="FAIL"
	fi
	ended="$(date -Iseconds)"
	append_result "$INDEX" "$target" "$expected" "$actual" "$rc" "$result" "$started" "$ended" "$log"

	LAST_RESULT="$result"
	LAST_LOG="$log"
	INDEX=$((INDEX + 1))
	save_state

	if [ "$INDEX" -ge "$(target_count)" ]; then
		finish_and_return_baseline
	fi
	apply_current_and_reboot
}

abort_run() {
	need_root
	with_lock
	load_state
	PHASE="aborted"
	LAST_RESULT="aborted"
	save_state
	disable_service
	warn "Autotest aborted. Returning to 24CU mode7 baseline."
	"$MASK" baseline
	sync
	sleep "${BC250_AUTOTEST_REBOOT_DELAY:-3}"
	systemctl reboot
}

show_queue() {
	local mode="${1:-}"
	local queue=""
	local -a targets=()
	local i

	case "$mode" in
		singles)
			queue="$SINGLE_QUEUE"
			;;
		matrix)
			queue="$(matrix_queue "${2:-}" "${3:-}")"
			;;
		repeat)
			queue="$(repeat_queue "${2:-}" "${3:-}")"
			;;
		*)
			usage >&2
			exit 2
			;;
	esac

	read -ra targets <<<"$queue"
	printf 'index\ttarget\texpected_num_cu\n'
	for i in "${!targets[@]}"; do
		printf '%s\t%s\t%s\n' "$i" "${targets[$i]}" "$(expected_num_cu_for_target "${targets[$i]}")"
	done
}

show_status() {
	load_state
	echo "state_dir=$STATE_DIR"
	echo "phase=$PHASE"
	echo "mode=$MODE"
	echo "index=$INDEX/$(target_count 2>/dev/null || echo 0)"
	echo "current_target=$CURRENT_TARGET"
	echo "run_user=$RUN_USER"
	echo "verify=$VERIFY_BIN $VERIFY_MODE $VERIFY_ARGS"
	echo "last_result=$LAST_RESULT"
	echo "last_log=$LAST_LOG"
	echo "results=$RESULTS_FILE"
	if command -v systemctl >/dev/null 2>&1; then
		echo "service_enabled=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
	fi
}

show_report() {
	local best_target="" best_cu=0

	if [ ! -f "$RESULTS_FILE" ]; then
		echo "No results yet: $RESULTS_FILE"
		return 0
	fi
	if command -v column >/dev/null 2>&1; then
		column -t -s $'\t' "$RESULTS_FILE"
	else
		cat "$RESULTS_FILE"
	fi
	best_target="$(awk -F'\t' 'NR > 1 && $6 == "PASS" && $2 != "none" && $3 + 0 > best { best = $3 + 0; target = $2 } END { print target }' "$RESULTS_FILE")"
	best_cu="$(awk -F'\t' 'NR > 1 && $6 == "PASS" && $2 != "none" && $3 + 0 > best { best = $3 + 0 } END { print best + 0 }' "$RESULTS_FILE")"
	echo
	echo "recommended_active_extra_wgps=${best_target:-none}"
	echo "recommended_num_cu=${best_cu:-0}"
}

install_recommended() {
	local target

	need_root
	target="$(awk -F'\t' 'NR > 1 && $6 == "PASS" && $2 != "none" && $3 + 0 > best { best = $3 + 0; target = $2 } END { print target }' "$RESULTS_FILE" 2>/dev/null || true)"
	[ -n "$target" ] || die "no PASS target found in $RESULTS_FILE"
	"$MASK" apply-extra-set "$target"
	echo "recommended_active_extra_wgps=$target"
}

case "${1:-}" in
	start)
		case "${2:-}" in
			singles)
				shift 2
				start_queue singles "$SINGLE_QUEUE" "$*"
				;;
			auto)
				shift 2
				start_queue auto "$SINGLE_QUEUE" "$*"
				;;
			matrix)
				good="${3:-}"
				count="${4:-}"
				shift 4 || true
				start_queue matrix "$(matrix_queue "$good" "$count")" "$*"
				;;
			repeat)
				target="${3:-}"
				count="${4:-}"
				shift 4 || true
				start_queue repeat "$(repeat_queue "$target" "$count")" "$*"
				;;
			*)
				usage >&2
				exit 2
				;;
		esac
		;;
	resume)
		resume_run
		;;
	abort)
		abort_run
		;;
	status)
		show_status
		;;
	report)
		show_report
		;;
	queue)
		show_queue "${2:-}" "${3:-}" "${4:-}"
		;;
	install-recommended)
		install_recommended
		;;
	print-service)
		print_service
		;;
	-h|--help|"")
		usage
		;;
	*)
		usage >&2
		exit 2
		;;
esac

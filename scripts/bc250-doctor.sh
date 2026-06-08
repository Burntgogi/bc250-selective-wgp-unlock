#!/usr/bin/env bash
# Onboarding checker for BC-250 selective WGP unlock.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT=0

usage() {
	cat <<EOF
Usage:
  ./scripts/bc250-doctor.sh [check] [--strict]
  ./scripts/bc250-doctor.sh --help

Runs non-destructive readiness checks and prints the next command to run.

Checks:
  - BC-250 PCI device visibility
  - patched amdgpu module and mode7 support
  - current Vulkan CU count
  - required build/test tools
  - repository scripts and docs
EOF
}

ok() {
	printf '[ OK ] %s\n' "$*"
}

warn() {
	printf '[WARN] %s\n' "$*"
}

fail() {
	printf '[FAIL] %s\n' "$*"
	if [ "$STRICT" = "1" ]; then
		return 1
	fi
	return 0
}

have() {
	command -v "$1" >/dev/null 2>&1
}

safe_modinfo_has() {
	local pattern="$1"
	( set +o pipefail; modinfo amdgpu 2>/dev/null | grep -qa "$pattern" )
}

current_write_mode() {
	cat /sys/module/amdgpu/parameters/bc250_cc_write_mode 2>/dev/null || true
}

current_num_cu() {
	if ! have vulkaninfo; then
		return 1
	fi
	RADV_DEBUG=info vulkaninfo --summary 2>/dev/null |
		awk -F= '/num_cu =/ { gsub(/[ \t]/, "", $2); print $2; exit }'
}

check_repo_files() {
	local rc=0
	local file
	for file in \
		README.md \
		patch/bc250-40cu-amdgpu.patch \
		scripts/bc250-enable-40cu.sh \
		scripts/bc250-mode7-mask.sh \
		scripts/bc250-wgp-autotest.sh \
		scripts/bc250-fast-kernel-suite.sh \
		scripts/bc250-compute-verify.sh \
		docs/quickstart.md \
		docs/selective-wgp-unlock.md; do
		if [ -f "$ROOT/$file" ]; then
			ok "repo file present: $file"
		else
			fail "missing repo file: $file" || rc=1
		fi
	done
	return "$rc"
}

check_tools() {
	local rc=0
	local tool
	for tool in gcc make zstd glslangValidator; do
		if have "$tool"; then
			ok "tool found: $tool"
		else
			fail "tool missing: $tool" || rc=1
		fi
	done
	if have patch; then
		ok "tool found: patch"
	else
		fail "tool missing: patch" || rc=1
	fi
	if have vulkaninfo; then
		ok "tool found: vulkaninfo"
	else
		fail "tool missing: vulkaninfo" || rc=1
	fi
	return "$rc"
}

check_hardware() {
	local rc=0
	local mode num_cu

	if have lspci && lspci -nn 2>/dev/null | grep -qi '13fe'; then
		ok "BC-250 PCI device detected"
	else
		fail "BC-250 PCI device was not detected by lspci" || rc=1
	fi

	if safe_modinfo_has 'bc250_cc_write_mode'; then
		ok "amdgpu module advertises bc250_cc_write_mode"
	else
		fail "amdgpu module does not advertise bc250_cc_write_mode; run sudo ./scripts/bc250-enable-40cu.sh build" || rc=1
	fi

	if safe_modinfo_has '7=coherent-disable-cus'; then
		ok "amdgpu module advertises mode7 coherent-disable-cus"
	else
		fail "amdgpu module does not advertise mode7; rebuild with this repository patch" || rc=1
	fi

	mode="$(current_write_mode)"
	if [ -n "$mode" ]; then
		ok "current bc250_cc_write_mode=$mode"
	else
		warn "bc250_cc_write_mode is not visible; amdgpu may not be loaded"
	fi

	num_cu="$(current_num_cu || true)"
	if [ -n "$num_cu" ]; then
		ok "Vulkan reports num_cu=$num_cu"
	else
		fail "Vulkan CU count was not available; check Vulkan/RADV setup and /dev/dri permissions" || rc=1
	fi

	return "$rc"
}

print_next_steps() {
	cat <<'EOF'

Next commands:
  1. Read the guided path:
     docs/quickstart.md

  2. If mode7 is not available:
     sudo ./scripts/bc250-enable-40cu.sh build
     sudo reboot

  3. Validate the current configuration without model files:
     ./scripts/bc250-fast-kernel-suite.sh gate

  4. Start single extra-WGP discovery:
     sudo ./scripts/bc250-wgp-autotest.sh start singles

  5. After the rebooting run finishes:
     ./scripts/bc250-wgp-autotest.sh report
EOF
}

run_check() {
	local rc=0

	echo "== BC-250 Selective WGP Unlock Doctor =="
	echo
	check_repo_files || rc=1
	echo
	check_tools || rc=1
	echo
	check_hardware || rc=1
	print_next_steps

	return "$rc"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		check)
			shift
			;;
		--strict)
			STRICT=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			usage >&2
			exit 2
			;;
	esac
done

run_check

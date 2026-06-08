#!/usr/bin/env bash
# Model-free Vulkan compute gates for BC-250 WGP validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="${BC250_COMPUTE_VERIFY:-$SCRIPT_DIR/bc250-compute-verify.sh}"
MATMUL_VERIFY="${BC250_QUANT_MATMUL_VERIFY:-$SCRIPT_DIR/bc250-quant-matmul-verify.sh}"

usage() {
	cat <<EOF
Usage:
  ./scripts/bc250-fast-kernel-suite.sh quick
  ./scripts/bc250-fast-kernel-suite.sh gate [ELEMENTS PASSES ITERS]
  ./scripts/bc250-fast-kernel-suite.sh stress
  ./scripts/bc250-fast-kernel-suite.sh quant-matmul [ARGS...]
  ./scripts/bc250-fast-kernel-suite.sh custom ELEMENTS PASSES ITERS

Profiles:
  quick        262144 elements, 1 pass, 4 iterations
  gate         4194304 elements, 2 passes, 32 iterations
  stress       quick + gate + larger long-running compute profile
  quant-matmul quantized matrix multiply verifier, no model files required
EOF
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

setup_vulkan_build_env() {
	local prefix libdir
	local -a prefixes=()

	[ -z "${BC250_VULKAN_PREFIX:-}" ] || prefixes+=("$BC250_VULKAN_PREFIX")
	prefixes+=("$HOME/.local/vulkan/usr" "/usr/local" "/usr")

	for prefix in "${prefixes[@]}"; do
		if [ -f "$prefix/include/vulkan/vulkan.h" ]; then
			export CPATH="$prefix/include${CPATH:+:$CPATH}"
		fi
		for libdir in "$prefix/lib/x86_64-linux-gnu" "$prefix/lib64" "$prefix/lib"; do
			if [ -e "$libdir/libvulkan.so" ]; then
				export LIBRARY_PATH="$libdir${LIBRARY_PATH:+:$LIBRARY_PATH}"
				export LD_LIBRARY_PATH="$libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
			fi
		done
	done

	for libdir in "$HOME/.local/gcc/usr/lib/x86_64-linux-gnu" "$HOME/.local/gcc/usr/lib64" "$HOME/.local/gcc/usr/lib"; do
		if [ -d "$libdir" ]; then
			export LD_LIBRARY_PATH="$libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
		fi
	done
}

run_compute() {
	local elements="$1"
	local passes="$2"
	local iters="$3"

	[ -x "$VERIFY" ] || die "compute verifier is not executable: $VERIFY"
	setup_vulkan_build_env
	"$VERIFY" --elements "$elements" --passes "$passes" --iters "$iters"
}

case "${1:-gate}" in
	quick)
		run_compute 262144 1 4
		;;
	gate)
		shift || true
		if [ "$#" -eq 3 ]; then
			run_compute "$1" "$2" "$3"
		elif [ "$#" -eq 0 ]; then
			run_compute 4194304 2 32
		else
			usage >&2
			exit 2
		fi
		;;
	stress)
		run_compute 262144 1 4
		run_compute 4194304 2 32
		run_compute 16777216 3 64
		setup_vulkan_build_env
		"$MATMUL_VERIFY" --rows 128 --cols 128 --k 1024 --passes 4
		;;
	quant-matmul)
		shift || true
		[ -x "$MATMUL_VERIFY" ] || die "quantized matmul verifier is not executable: $MATMUL_VERIFY"
		setup_vulkan_build_env
		"$MATMUL_VERIFY" "$@"
		;;
	custom)
		shift || true
		[ "$#" -eq 3 ] || {
			usage >&2
			exit 2
		}
		run_compute "$1" "$2" "$3"
		;;
	-h|--help)
		usage
		;;
	*)
		usage >&2
		exit 2
		;;
esac

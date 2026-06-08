#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# bc250-enable-40cu.sh — Build and install a patched amdgpu for 40 CU on BC-250
#
# Usage:
#   sudo ./bc250-enable-40cu.sh build     # patch + compile + install
#   sudo ./bc250-enable-40cu.sh enable    # set 40 CU mode and reboot
#   sudo ./bc250-enable-40cu.sh disable   # return to stock 24 CU and reboot
#   sudo ./bc250-enable-40cu.sh status    # show current CU state
#   sudo ./bc250-enable-40cu.sh restore   # restore original amdgpu module
#
# Requirements: kernel headers, gcc, make, zstd. Must run as root on BC-250.
# Tested on: Debian Forky kernel 6.19.14+deb14-amd64
#
# Derived from duggasco/bc250-40cu-unlock; downstream mode7 changes by this repository.
# License: GPL-2.0-only. See ../LICENSES/GPL-2.0-only.txt.

set -euo pipefail

KVER="$(uname -r)"
MODDIR="/lib/modules/${KVER}"
MODPATH="${MODDIR}/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
MODSRC=""
BUILDDIR="/tmp/bc250-40cu-build"
CONF40="/etc/modprobe.d/bc250-40cu.conf"
BACKUP_SUFFIX=".bc250-backup-$(date +%Y%m%d)"
BC250_PCI_ID="13fe"

info()  { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m[!]\033[0m %s\n' "$*"; }
err()   { printf '\033[0;31m[E]\033[0m %s\n' "$*" >&2; }
die()   { err "$@"; exit 1; }

write_param_patch() {
    cat > "$1" << 'ENDPARAM'

/* BC-250 CU control: clears or reduces harvest mask + enables SPI dispatch WGPs */
static int bc250_cc_write_mode;
module_param(bc250_cc_write_mode, int, 0444);
MODULE_PARM_DESC(bc250_cc_write_mode,
	"BC-250: 0=off 1=probe-SE0SH0 2=clear-SE0SH0 3=40CU-clear-all-SAs 4=probe-all-SAs 5=32CU-wgp4-off 6=32CU-wgp3-off 7=coherent-disable-cus");
#define BC250_PCI_DEVICE_ID 0x13FE

ENDPARAM
}

write_cc_patch() {
    cat > "$1" << 'ENDCC'

	/* BC-250: control harvested CUs — CC (enumeration) + SPI (dispatch) + RLC (power)
	 * Stock BC-250 exposes 3 WGP/SH = 24 CU. Full mode exposes 5 WGP/SH = 40 CU.
	 * 32CU modes expose 4 WGP/SH: 2 SE * 2 SH/SE * 4 WGP/SH * 2 CU/WGP.
	 */
	if (bc250_cc_write_mode > 0 && adev->pdev->device == BC250_PCI_DEVICE_ID) {
		int bc_se, bc_sh;
		for (bc_se = 0; bc_se < adev->gfx.config.max_shader_engines; bc_se++) {
			for (bc_sh = 0; bc_sh < adev->gfx.config.max_sh_per_se; bc_sh++) {
				u32 bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after;
				u32 bc_cc_target = 0;
				u32 bc_wgp_mask = 0x1f;
				u32 bc_target_cu = 40;
				u32 bc_disable_wgp = 0;
				if (bc250_cc_write_mode == 2 && (bc_se > 0 || bc_sh > 0))
					continue;
				if (bc250_cc_write_mode == 5) {
					bc_cc_target = 0x00100000;
					bc_wgp_mask = 0x0f;
					bc_target_cu = 32;
				} else if (bc250_cc_write_mode == 6) {
					bc_cc_target = 0x00080000;
					bc_wgp_mask = 0x17;
					bc_target_cu = 32;
				} else if (bc250_cc_write_mode == 7) {
					bc_disable_wgp = disable_masks[bc_se * 2 + bc_sh] & 0x1f;
					bc_cc_target = bc_disable_wgp << GC_USER_SHADER_ARRAY_CONFIG__INACTIVE_WGPS__SHIFT;
					bc_wgp_mask = 0x1f & ~bc_disable_wgp;
					bc_target_cu = 0;
				}
				gfx_v10_0_select_se_sh(adev, bc_se, bc_sh, 0xffffffff, 0);
				bc_cc_orig = RREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG);
				WREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG, bc_cc_target);
				bc_cc_after = RREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG);
				bc_spi_orig = RREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK);
				WREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK, bc_wgp_mask);
				bc_spi_after = RREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK);
				WREG32_SOC15(GC, 0, mmRLC_PG_ALWAYS_ON_WGP_MASK, bc_wgp_mask);
				if (bc250_cc_write_mode == 1 || bc250_cc_write_mode == 4) {
					WREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG, bc_cc_orig);
					WREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK, bc_spi_orig);
					dev_info(adev->dev,
						"bc250-40cu-probe: se=%d sh=%d CC=0x%08x->0x%08x SPI=0x%08x->0x%08x (restored)",
						bc_se, bc_sh, bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after);
				} else {
					dev_info(adev->dev,
						"bc250-cu-enable: mode=%d target_cu=%u se=%d sh=%d CC=0x%08x->0x%08x SPI=0x%08x->0x%08x WGP_MASK=0x%08x",
						bc250_cc_write_mode, bc_target_cu, bc_se, bc_sh,
						bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after,
						bc_wgp_mask);
				}
			}
		}
		gfx_v10_0_select_se_sh(adev, 0xffffffff, 0xffffffff, 0xffffffff, 0);
	}

ENDCC
}

check_bc250() {
    if ! lspci -nn 2>/dev/null | grep -qi "${BC250_PCI_ID}"; then
        warn "No BC-250 (PCI ID 13fe) detected. This patch is BC-250 specific."
        printf "Continue anyway? [y/N] "
        read -r ans
        case "$ans" in y|Y) ;; *) exit 1 ;; esac
    fi
}

check_deps() {
    local missing=""
    command -v gcc  >/dev/null 2>&1 || missing="${missing} gcc"
    command -v make >/dev/null 2>&1 || missing="${missing} make"
    command -v zstd >/dev/null 2>&1 || missing="${missing} zstd"
    if [ ! -d "${MODDIR}/build" ]; then
        missing="${missing} linux-headers-${KVER}"
    fi
    if [ -n "$missing" ]; then
        die "Missing dependencies:${missing}"
    fi
}

find_source() {
    local d
    for d in \
        "/usr/src/linux-source-${KVER%%-*}" \
        "/usr/src/linux-source-${KVER%%+*}" \
        "/usr/src/linux-${KVER}" \
        "/usr/src/linux"; do
        if [ -f "$d/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c" ]; then
            MODSRC="$d"
            return 0
        fi
    done

    local srcpkg=""
    local p
    for p in \
        "/usr/src/linux-source-${KVER%%-*}.tar.xz" \
        "/usr/src/linux-source-${KVER%%+*}.tar.xz"; do
        [ -f "$p" ] && srcpkg="$p" && break
    done
    if [ -z "$srcpkg" ]; then
        srcpkg="$(find /usr/src -maxdepth 4 -name 'linux-source-*.tar.xz' 2>/dev/null | head -1)"
    fi

    if [ -n "$srcpkg" ]; then
        info "Extracting kernel source from ${srcpkg}..."
        mkdir -p "${BUILDDIR}/src"
        tar xf "$srcpkg" -C "${BUILDDIR}/src" --strip-components=1 \
            '*/drivers/gpu/drm/amd/amdgpu/' 2>/dev/null || true
        if [ -f "${BUILDDIR}/src/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c" ]; then
            MODSRC="${BUILDDIR}/src"
            return 0
        fi
    fi

    info "Kernel source not found locally. Trying apt..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y "linux-source-${KVER%%-*}" 2>/dev/null || true
        srcpkg="/usr/src/linux-source-${KVER%%-*}.tar.xz"
        if [ -f "$srcpkg" ]; then
            mkdir -p "${BUILDDIR}/src"
            tar xf "$srcpkg" -C "${BUILDDIR}/src" --strip-components=1 \
                '*/drivers/gpu/drm/amd/amdgpu/' 2>/dev/null || true
            if [ -f "${BUILDDIR}/src/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c" ]; then
                MODSRC="${BUILDDIR}/src"
                return 0
            fi
        fi
    fi

    die "Cannot find kernel source for ${KVER}. Install matching kernel source, or set BC250_KERNEL_SOURCE."
}

patch_source() {
    local gfx="${MODSRC}/drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c"
    [ -f "$gfx" ] || die "gfx_v10_0.c not found at ${gfx}"

    if grep -q 'bc250_cc_write_mode' "$gfx"; then
        if grep -q 'coherent-disable-cus' "$gfx"; then
            info "Source already has coherent selective BC-250 patch."
            return 0
        fi
        command -v python3 >/dev/null 2>&1 ||
            die "Source has an older BC-250 patch without mode7 and python3 is needed to upgrade it."
        info "Upgrading older BC-250 source patch to coherent selective mode7."
        cp "$gfx" "${gfx}.pre-bc250-mode7-$(date +%Y%m%d%H%M%S)"

        local cc_file
        cc_file="$(mktemp)"
        write_cc_patch "$cc_file"
        python3 - "$gfx" "$cc_file" <<'PY'
import pathlib
import re
import sys

gfx = pathlib.Path(sys.argv[1])
cc_file = pathlib.Path(sys.argv[2])
text = gfx.read_text(encoding="utf-8", errors="surrogateescape")
cc_block = cc_file.read_text(encoding="utf-8", errors="surrogateescape").strip("\n")

desc = (
    'MODULE_PARM_DESC(bc250_cc_write_mode,\n'
    '\t"BC-250: 0=off 1=probe-SE0SH0 2=clear-SE0SH0 '
    '3=40CU-clear-all-SAs 4=probe-all-SAs 5=32CU-wgp4-off '
    '6=32CU-wgp3-off 7=coherent-disable-cus");'
)
text, desc_count = re.subn(
    r'MODULE_PARM_DESC\(bc250_cc_write_mode,\n\t"BC-250: .*?"\);',
    desc,
    text,
    count=1,
    flags=re.S,
)
if desc_count != 1:
    raise SystemExit("failed to update MODULE_PARM_DESC")

start_markers = (
    "\t/* BC-250: unlock harvested CUs",
    "\t/* BC-250: control harvested CUs",
)
start = -1
for marker in start_markers:
    start = text.find(marker)
    if start >= 0:
        break
if start < 0:
    raise SystemExit("failed to locate existing BC-250 patch block")

end = text.find("\n\n\tfor (i = 0;", start)
if end < 0:
    raise SystemExit("failed to locate end of existing BC-250 patch block")

text = text[:start] + cc_block + text[end:]
gfx.write_text(text, encoding="utf-8", errors="surrogateescape")
PY
        rm -f "$cc_file"
        grep -q 'coherent-disable-cus' "$gfx" || die "Failed to upgrade source patch to mode7."
        return 0
    fi

    info "Patching gfx_v10_0.c..."
    cp "$gfx" "${gfx}.orig"

    # Step 1: insert module parameter before '#include "amdgpu.h"'
    if ! grep -q '#include "amdgpu.h"' "$gfx"; then
        die "Cannot find anchor: #include amdgpu.h"
    fi

    local param_file
    param_file="$(mktemp)"
    write_param_patch "$param_file"
    sed -i "/#include \"amdgpu.h\"/r ${param_file}" "$gfx"
    rm -f "$param_file"

    # Step 2: insert CC write block in gfx_v10_0_get_cu_info after mutex_lock
    local cc_file
    cc_file="$(mktemp)"
    write_cc_patch "$cc_file"

    awk -v insertfile="$cc_file" '
    /static.*gfx_v10_0_get_cu_info/ { maybe_func = 1 }
    maybe_func && /;/ { maybe_func = 0 }
    maybe_func && /^[[:space:]]*\{/ {
        in_cu_info = 1
        maybe_func = 0
    }
    in_cu_info && /mutex_lock/ && !inserted {
        print
        while ((getline line < insertfile) > 0) print line
        close(insertfile)
        inserted = 1
        next
    }
    { print }
    ' "$gfx" > "${gfx}.new"

    if grep -q 'coherent-disable-cus' "${gfx}.new" && grep -q 'bc250-cu-enable' "${gfx}.new"; then
        mv "${gfx}.new" "$gfx"
        rm -f "$cc_file"
        info "Patch applied successfully."
    else
        rm -f "${gfx}.new" "$cc_file"
        mv "${gfx}.orig" "$gfx"
        die "Failed to insert CC write block. Kernel source layout may differ."
    fi
}

build_module() {
    local amdgpu_dir="${MODSRC}/drivers/gpu/drm/amd/amdgpu"
    [ -d "$amdgpu_dir" ] || die "amdgpu source directory not found"

    info "Building amdgpu module for kernel ${KVER} (2-5 min)..."
    make -C "${MODDIR}/build" M="$amdgpu_dir" -j"$(nproc)" modules 2>&1 | tail -5

    local built="${amdgpu_dir}/amdgpu.ko"
    [ -f "$built" ] || die "Build failed - amdgpu.ko not produced"

    if ! strings "$built" | grep -q 'bc250_cc_write_mode'; then
        die "Built module missing bc250_cc_write_mode - patch failed"
    fi

    info "Build successful: ${built} ($(du -h "$built" | cut -f1))"
    echo "$built"
}

install_module() {
    local built="$1"
    local target="${MODPATH}"

    if [ -f "${target}.zst" ]; then
        target="${target}.zst"
    elif [ ! -f "$target" ]; then
        target="${target}.zst"
    fi

    if [ -f "$target" ] && [ ! -f "${target}${BACKUP_SUFFIX}" ]; then
        info "Backing up original to ${target}${BACKUP_SUFFIX}"
        cp "$target" "${target}${BACKUP_SUFFIX}"
    fi

    if [ "${target%.zst}" != "$target" ]; then
        info "Compressing and installing module..."
        zstd -f "$built" -o "$target"
    else
        cp "$built" "$target"
    fi

    depmod -a "$KVER"
    info "Module installed at ${target}"
}

do_build() {
    check_bc250
    check_deps
    find_source
    patch_source
    local built
    built="$(build_module)"
    install_module "$built"
    echo ""
    info "Done! Patched amdgpu module installed."
    info "Next: sudo ./scripts/bc250-enable-40cu.sh enable"
}

do_enable() {
    printf '# BC-250 40 CU re-enablement\noptions amdgpu bc250_cc_write_mode=3\n' > "$CONF40"
    info "40 CU mode configured in ${CONF40}"
    if ! ( set +o pipefail; modinfo amdgpu 2>/dev/null | grep -qa 'bc250_cc_write_mode' ); then
        warn "Patched module not detected. Run: sudo $0 build"
        rm -f "$CONF40"
        exit 1
    fi
    info "Rebooting..."
    sleep 2
    reboot
}

do_disable() {
    rm -f "$CONF40"
    info "40 CU config removed. Rebooting to stock 24 CU..."
    sleep 2
    reboot
}

do_restore() {
    local target="${MODPATH}"
    if [ -f "${target}.zst" ]; then target="${target}.zst"; fi
    local backup
    backup="$(ls -1 "${target}.bc250-backup-"* 2>/dev/null | head -1)"
    [ -n "$backup" ] || die "No backup found"
    cp "$backup" "$target"
    rm -f "$CONF40"
    depmod -a "$KVER"
    info "Original module restored. Reboot to apply."
}

do_status() {
    printf '\033[1m=== BC-250 CU Status ===\033[0m\n\n'

    if lspci -nn 2>/dev/null | grep -qi "${BC250_PCI_ID}"; then
        printf '  PCI device:     \033[0;32mBC-250 detected\033[0m\n'
    else
        printf '  PCI device:     \033[0;31mBC-250 not found\033[0m\n'
    fi

    if ( set +o pipefail; modinfo amdgpu 2>/dev/null | grep -qa 'bc250_cc_write_mode' ); then
        printf '  amdgpu module:  \033[0;32mpatched\033[0m\n'
    else
        printf '  amdgpu module:  \033[0;33mstock (unpatched)\033[0m\n'
    fi

    local mode
    mode="$(cat /sys/module/amdgpu/parameters/bc250_cc_write_mode 2>/dev/null || echo 'N/A')"
    printf '  write_mode:     %s\n' "$mode"

    local cu_line
    cu_line="$(dmesg 2>/dev/null | grep 'active_cu_number' | tail -1 || true)"
    if [ -n "$cu_line" ]; then
        local cus
        cus="$(echo "$cu_line" | grep -o 'active_cu_number [0-9]*' | awk '{print $2}')"
        if [ "$cus" = "40" ]; then
            printf '  active CUs:     \033[0;32m\033[1m40\033[0m (full die)\n'
        elif [ "$cus" = "24" ]; then
            printf '  active CUs:     \033[0;33m24\033[0m (stock)\n'
        else
            printf '  active CUs:     %s\n' "$cus"
        fi
    fi

    if [ -f "$CONF40" ]; then
        if grep -q 'bc250_cc_write_mode=7' "$CONF40"; then
            printf '  modprobe conf:  \033[0;32m%s (coherent selective mode)\033[0m\n' "$CONF40"
        elif grep -q 'bc250_cc_write_mode=3' "$CONF40"; then
            printf '  modprobe conf:  \033[0;32m%s (40 CU enabled)\033[0m\n' "$CONF40"
        else
            printf '  modprobe conf:  \033[0;32m%s (BC-250 config present)\033[0m\n' "$CONF40"
        fi
    else
        printf '  modprobe conf:  (none - stock mode)\n'
    fi
    echo ""
}

case "${1:-}" in
    build)   do_build ;;
    enable)  do_enable ;;
    disable) do_disable ;;
    restore) do_restore ;;
    status)  do_status ;;
    *)
        echo "BC-250 40 CU Re-enablement Tool"
        echo ""
        echo "Usage: sudo ./scripts/bc250-enable-40cu.sh <command>"
        echo ""
        echo "  build     Patch, compile, install patched amdgpu (~5 min)"
        echo "  enable    Activate 40 CU mode and reboot"
        echo "  disable   Return to stock 24 CU and reboot"
        echo "  status    Show current CU state"
        echo "  restore   Restore original amdgpu module"
        echo ""
        echo "Quick start:"
        echo "  sudo ./scripts/bc250-enable-40cu.sh build && sudo ./scripts/bc250-enable-40cu.sh enable"
        echo ""
        echo "Selective mode:"
        echo "  ./scripts/bc250-mode7-mask.sh module-check"
        echo "  ./scripts/bc250-wgp-autotest.sh queue singles"
        ;;
esac

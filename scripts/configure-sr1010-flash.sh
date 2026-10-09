#!/bin/sh
# Configure ImmortalWrt to build the flashable vendor-format SR1010 image.
#
#   SR1010_VENDOR_TEMPLATE  absolute path of a vendor upgrade package (.bin)
#   KERNEL_TREE             prepared ZX279133 kernel tree (default: sibling dir)
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEFAULT_KERNEL_TREE="$TOPDIR/../linux-mainline-zte-zxslc-sr1010/linux-6.18.38"
KERNEL_TREE=${KERNEL_TREE:-$DEFAULT_KERNEL_TREE}

if [ -z "${SR1010_VENDOR_TEMPLATE:-}" ] || [ ! -f "$SR1010_VENDOR_TEMPLATE" ]; then
	echo "set SR1010_VENDOR_TEMPLATE to a vendor upgrade package (.bin)" >&2
	exit 1
fi

if [ ! -f "$KERNEL_TREE/Makefile" ] || [ ! -f "$KERNEL_TREE/arch/arm64/boot/dts/zte/zx279133-sr1010.dts" ]; then
	echo "invalid ZX279133 kernel tree: $KERNEL_TREE" >&2
	exit 1
fi

KERNEL_TREE=$(CDPATH= cd -- "$KERNEL_TREE" && pwd)

# The kernel embeds the network microcode from this tree; CONFIG_EXTRA_FIRMWARE_DIR
# in target/linux/zte/zx279133/config-6.18 is relative to the kernel tree.
FIRMWARE_DIR=$(CDPATH= cd -- "$KERNEL_TREE/../../immortalwrt/target/linux/zte/zx279133/firmware" 2>/dev/null && pwd) || true
if [ "$FIRMWARE_DIR" != "$TOPDIR/target/linux/zte/zx279133/firmware" ]; then
	echo "the kernel tree must be <dir>/linux-mainline-zte-zxslc-sr1010/linux-6.18.38 next to <dir>/immortalwrt:" >&2
	echo "  $KERNEL_TREE/../../immortalwrt does not lead back to $TOPDIR" >&2
	exit 1
fi
SR1010_VENDOR_TEMPLATE=$(CDPATH= cd -- "$(dirname -- "$SR1010_VENDOR_TEMPLATE")" && pwd)/$(basename -- "$SR1010_VENDOR_TEMPLATE")
cd "$TOPDIR"

if [ -f .config ]; then
	mkdir -p tmp
	cp .config tmp/.config.before-sr1010
	echo "saved previous configuration as tmp/.config.before-sr1010"
fi

cp configs/zte_zx279133_sr1010_squashfs.config .config
printf 'CONFIG_EXTERNAL_KERNEL_TREE="%s"\n' "$KERNEL_TREE" >> .config
printf 'CONFIG_SR1010_VENDOR_TEMPLATE="%s"\n' "$SR1010_VENDOR_TEMPLATE" >> .config

make defconfig

cat <<MSG

SR1010 flashable image configuration is ready.
Build with:
  make -j\$(nproc)

Expected image:
  bin/targets/zte/zx279133/immortalwrt-zte-zx279133-zte_zxslc-sr1010-flash-squashfs-sysupgrade.bin
MSG

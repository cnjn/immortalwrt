#!/bin/sh
# Configure ImmortalWrt to build a U-Boot FIT initramfs for the ZXSLC SR1010.
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEFAULT_KERNEL_TREE="$TOPDIR/../linux-mainline-zte-zxslc-sr1010/linux-6.18.38"
KERNEL_TREE=${KERNEL_TREE:-$DEFAULT_KERNEL_TREE}

if [ ! -f "$KERNEL_TREE/Makefile" ] || [ ! -f "$KERNEL_TREE/arch/arm64/boot/dts/zte/zx279133-sr1010.dts" ]; then
	echo "invalid ZX279133 kernel tree: $KERNEL_TREE" >&2
	exit 1
fi

KERNEL_TREE=$(CDPATH= cd -- "$KERNEL_TREE" && pwd)
cd "$TOPDIR"

if [ -f .config ]; then
	mkdir -p tmp
	cp .config tmp/.config.before-sr1010
	echo "saved previous configuration as tmp/.config.before-sr1010"
fi

cp configs/zte_zx279133_sr1010_initramfs.config .config
printf 'CONFIG_EXTERNAL_KERNEL_TREE="%s"\n' "$KERNEL_TREE" >> .config

make defconfig

cat <<EOF

SR1010 initramfs configuration is ready.
Build with:
  make -j\$(nproc)

Expected image:
  bin/targets/zte/zx279133/immortalwrt-zte-zx279133-zte_zxslc-sr1010-initramfs.itb
EOF

#!/bin/sh
# Configure ImmortalWrt to build a U-Boot FIT initramfs for the ZXSLC SR1010.
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TOPDIR"

if [ -f .config ]; then
	mkdir -p tmp
	cp .config tmp/.config.before-sr1010
	echo "saved previous configuration as tmp/.config.before-sr1010"
fi

cp configs/zte_zx279133_sr1010_initramfs.config .config

make defconfig

cat <<EOF

SR1010 initramfs configuration is ready.
Build with:
  make -j\$(nproc)

Expected image:
  bin/targets/zte/zx279133/immortalwrt-zte-zx279133-zte_zxslc-sr1010-initramfs.itb
EOF

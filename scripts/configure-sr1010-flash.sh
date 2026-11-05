#!/bin/sh
# Configure ImmortalWrt to build the flashable vendor-format SR1010 image.
#
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TOPDIR"

if [ -f .config ]; then
	mkdir -p tmp
	cp .config tmp/.config.before-sr1010
	echo "saved previous configuration as tmp/.config.before-sr1010"
fi

cp configs/zte_zx279133_sr1010_squashfs.config .config

make defconfig

cat <<MSG

SR1010 flashable image configuration is ready.
Build with:
  make -j\$(nproc)

Expected image:
  bin/targets/zte/zx279133/immortalwrt-zte-zx279133-zte_zxslc-sr1010-squashfs-sysupgrade.bin
MSG

#!/bin/sh
# Run on ImmortalWrt BEFORE switching to the vendor system.
# Makes 20 files of 64 KiB of random data in /root/canary. /root is in the overlay,
# so they end up in the Plugin partition, under .owrt/upper/root/canary.
# Their md5 list is kept in /root/canary.md5 (same flash!) and printed: copy it from the console.
D=${CANARY:-/root/canary}

mkdir -p "$D" || exit 1
cd "$D" || exit 1
i=0
while [ $i -lt 20 ]; do
	dd if=/dev/urandom of=f$i bs=1024 count=64 2>/dev/null || { echo "write failed"; exit 1; }
	i=$((i + 1))
done
md5sum f* > "$D.md5"
sync
echo "== the md5 list of the canary files (keep a copy off the router):"
cat "$D.md5"
if [ -r /sys/class/mtd/mtd6/ecc_failures ]; then
	echo "== mtd6 ecc_failures: $(cat /sys/class/mtd/mtd6/ecc_failures)"
fi
# a setting, to see whether the settings survive too
uci set system.@system[0].description="coexist-canary-$(date +%s)" && uci commit system &&
	echo "== setting marker: $(uci get system.@system[0].description)"
sync
echo "== now: zte-fwslot switch   (it reboots into the vendor system)"

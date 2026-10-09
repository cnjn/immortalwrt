#!/bin/sh
# Run on ImmortalWrt AFTER the vendor system has used the Plugin partition and OpenWrt is back.
# Checks the canary files, the files the vendor wrote (they sit in the root of the overlay's flash
# partition, /overlay/vtest) and looks at the kernel messages and the ECC counter.
D=${CANARY:-/root/canary}
LIST=${1:-$D.md5}
V=${VENDOR_DIR:-/overlay/vtest}
VLIST=${VENDOR_LIST:-/overlay/vtest.md5}

check() {		# dir list label
	[ -d "$1" ] || { echo "$3: $1 is missing"; return; }
	[ -r "$2" ] || { echo "$3: no list $2"; return; }
	cd "$1" || return
	md5sum * > /tmp/now.md5 2> /tmp/now.err
	n=0; b=0
	while read -r sum name; do
		n=$((n + 1))
		got=$(grep " $name\$" /tmp/now.md5 | cut -d' ' -f1)
		[ "$got" = "$sum" ] || { b=$((b + 1)); echo "   $3: $name differs or cannot be read"; }
	done < "$2"
	[ -s /tmp/now.err ] && { echo "   read errors:"; head -5 /tmp/now.err; }
	echo "$3: $b bad of $n"
	cd /
}

echo "== mounted: $(mount | grep ' /overlay ')"
check "$D" "$LIST" "OpenWrt canary files"
check "$V" "$VLIST" "files the vendor wrote"
if [ -r /sys/class/mtd/mtd6/ecc_failures ]; then
	echo "== mtd6 ecc_failures since this boot: $(cat /sys/class/mtd/mtd6/ecc_failures)"
fi
echo "== setting marker now: $(uci get system.@system[0].description 2>&1)   (owrt-prep.sh printed the value)"
echo "== kernel messages"
dmesg | grep -i -E 'jffs2|ecc|nand|mount_root' | grep -v CLEANMARKER | tail -30

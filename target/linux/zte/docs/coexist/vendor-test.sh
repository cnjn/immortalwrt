#!/bin/sh
# Run on the VENDOR system (busybox).   sh vendor-test.sh [quick|churn]
#   (the output goes to /tmp/vendor-test.log and the summary is printed at the end)
#   quick  writes 40 files of 256 KiB (10 MiB, random, so it cannot be compressed), remounts, checks.
#   churn  does that, then 4 rounds of: delete half of the files, write 20 new ones, remount, check.
#          The deleting and writing makes the vendor JFFS2 erase and reuse blocks and garbage collect,
#          which is where it may move the files of the OpenWrt side.
# Uses /Plugin and /dev/mtdblock9; PLUGIN= and MTDBLK= change that. DRYRUN=1 skips mount, umount and dmesg.
# Telnet loses the output that scrolls by: the whole run goes to a log, the summary is printed at the end.
LOG=${LOG:-/tmp/vendor-test.log}
if [ -z "$VT_INNER" ]; then
	VT_INNER=1 sh "$0" "$@" > "$LOG" 2>&1
	echo "(log: $LOG, $(wc -l < "$LOG") lines)"
	{ grep -E '^==|bad of|differs|read errors|FAILED|CANNOT|umount|cannot' "$LOG" 2>/dev/null || cat "$LOG"; } | tail -60
	exit 0
fi
P=${PLUGIN:-/Plugin}
B=${MTDBLK:-/dev/mtdblock9}
MODE=${1:-quick}
CAN=$P/.owrt/upper/root/canary
LIST=$P/.owrt/upper/root/canary.md5
bad_total=0

kmsg() {
	[ -n "$DRYRUN" ] && return 0
	dmesg 2>/dev/null | { grep -v CLEANMARKER 2>/dev/null || cat; } | tail -${1:-15}
}

is_mounted() {
	found=
	while read -r dev mp rest; do
		[ "$mp" = "$P" ] && found=1
	done < /proc/mounts
	[ -n "$found" ]
}

mount_it() {
	[ -n "$DRYRUN" ] && return 0
	is_mounted && return 0
	mount -t jffs2 "$B" "$P" || { echo "CANNOT MOUNT $B"; kmsg 25; exit 1; }
}

remount() {
	[ -n "$DRYRUN" ] && return 0
	cd /
	sync
	if umount "$P" 2>/dev/null; then
		mount -t jffs2 "$B" "$P" || { echo "MOUNT FAILED after a good umount (the vendor file system could not be mounted again)"; kmsg 25; exit 1; }
	else
		echo "   umount: $P is in use by vendor programs, so the file system is not mounted again; dropping the caches instead"
		echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || echo "   cannot drop the caches: the check below may read from RAM"
	fi
}

# check DIR LISTFILE LABEL: md5 of every file in DIR against the list; counts the bad ones.
# Plain shell, because the vendor busybox lacks applets.
check() {
	[ -d "$1" ] || { echo "$3: $1 is missing"; bad_total=$((bad_total + 1)); return; }
	cd "$1" || return
	md5sum * > /tmp/now.md5 2> /tmp/now.err
	n=0; b=0
	while read -r sum name; do
		n=$((n + 1))
		got=
		while read -r s2 n2; do
			[ "$n2" = "$name" ] && { got=$s2; break; }
		done < /tmp/now.md5
		[ "$got" = "$sum" ] || { b=$((b + 1)); echo "   $3: $name differs or cannot be read"; }
	done < "$2"
	[ -s /tmp/now.err ] && { echo "   read errors:"; head -5 /tmp/now.err; }
	echo "$3: $b bad of $n"
	bad_total=$((bad_total + b))
	cd /
}

write_files() {		# prefix count kib
	i=0
	while [ $i -lt $2 ]; do
		dd if=/dev/urandom of=$P/vtest/$1$i bs=1024 count=$3 2>/dev/null || { echo "write failed at $1$i (full?)"; return 1; }
		i=$((i + 1))
	done
}

mount_it
echo "== mounted at $P: $(is_mounted && echo yes || echo no)"
kmsg 8

echo "== 1. the files the OpenWrt side left (read by the vendor kernel)"
if [ -r "$LIST" ]; then
	check "$CAN" "$LIST" "canary"
else
	echo "   no $LIST: was owrt-prep.sh run, and is this the same Plugin?"
fi

echo "== 2. the vendor writes 40 files of 256 KiB"
mkdir -p $P/vtest
write_files a 40 256
(cd $P/vtest && md5sum a* > /tmp/vtest.md5)
cp /tmp/vtest.md5 $P/vtest.md5
sync
echo "   (md5 list of the vendor files is in /tmp/vtest.md5 and $P/vtest.md5)"
remount
echo "== 3. after unmount and mount again (read back from the flash)"
check "$P/vtest" /tmp/vtest.md5 "vendor files"
[ -r "$LIST" ] && check "$CAN" "$LIST" "canary"
kmsg 15

if [ "$MODE" = churn ]; then
	r=0
	while [ $r -lt 4 ]; do
		r=$((r + 1))
		echo "== churn round $r: delete every other file, write 20 new ones"
		k=0
		for f in $P/vtest/a*; do
			k=$((k + 1))
			[ $((k % 2)) -eq 0 ] && rm -f "$f"
		done
		write_files c${r}_ 20 256
		(cd $P/vtest && md5sum * > /tmp/vtest.md5)
		sync
		remount
		check "$P/vtest" /tmp/vtest.md5 "vendor files"
		[ -r "$LIST" ] && check "$CAN" "$LIST" "canary"
		kmsg 8
	done
fi

echo "== done: $bad_total bad file(s) in total"
echo "   the vendor kernel messages (look for 'cannot read OOB', 'CRC', 'Magic bitmask', -74):"
kmsg 40
echo "   next: flash the OpenWrt image again from the vendor web page, then run owrt-verify.sh"

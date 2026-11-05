#!/bin/sh
# Reject stale external-tree modules before they can enter an SR1010 image.
set -eu
expected=$1
strings_tool=$2
module=$3
actual=$("$strings_tool" "$module" | sed -n 's/^vermagic=\([^ ]*\).*/\1/p' | head -n 1)
if [ "$actual" != "$expected" ]; then
	printf 'ERROR: module %s has vermagic release "%s", expected "%s". Rebuild kernel modules with the firmware KERNELRELEASE/LOCALVERSION before packaging.\n' \
		"$module" "$actual" "$expected" >&2
	exit 1
fi

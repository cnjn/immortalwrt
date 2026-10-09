# SPDX-License-Identifier: GPL-2.0-only
#
# SR1010 sysupgrade. A vendor-format package is installed into the inactive
# firmware slot and the vendor bootloader starts it on the next boot. The same
# package also installs from the vendor web interface, so OpenWrt and the
# vendor firmware can be swapped in place.
#
# The overlay lives in the .owrt directory of the shared Plugin partition and
# the vendor files in the rest of that partition are never touched.

RAMFS_COPY_BIN='zte-fwslot'

platform_check_image() {
	zte-fwslot check "$1"
}

# Empty the overlay so stale files cannot shadow the new root filesystem, and
# stage the settings backup for restore on the next boot.
zte_reset_overlay() {
	local part mnt=/tmp/zte_overlay

	part=$(find_mtd_part Plugin)
	[ -n "$part" ] || {
		v "Plugin partition not found; the overlay is left in place"
		return 0
	}

	mkdir -p "$mnt"
	mount -t jffs2 "$part" "$mnt" || {
		v "cannot mount the Plugin partition; the overlay is left in place"
		rmdir "$mnt"
		return 0
	}

	rm -rf "$mnt/.owrt"
	mkdir "$mnt/.owrt"
	[ -n "$UPGRADE_BACKUP" ] && [ -f "$UPGRADE_BACKUP" ] &&
		cp "$UPGRADE_BACKUP" "$mnt/.owrt/${BACKUP_FILE:-sysupgrade.tgz}"

	sync
	umount "$mnt"
	rmdir "$mnt"
}

platform_do_upgrade() {
	zte-fwslot flash "$1" || {
		v "firmware flash failed; the running slot is unchanged"
		return 1
	}

	zte_reset_overlay
}

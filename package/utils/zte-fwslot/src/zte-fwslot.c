// SPDX-License-Identifier: GPL-2.0-only
/*
 * zte-fwslot - flash and select the SR1010 firmware slots from OpenWrt.
 *
 * The SR1010 keeps two firmware slots in flash. The vendor bootloader starts
 * the valid slot carrying the highest serial number. Images use the vendor
 * upgrade package format, so one file installs from either the vendor web UI
 * or OpenWrt, letting the two systems swap in place on this device.
 *
 * Flashing mirrors the vendor fw_flashing program: verify the package CRCs,
 * erase the inactive slot, write the package body to good erase blocks only,
 * then write the 512-byte version header to the next good block with a serial
 * larger than any other slot. "switch" only rewrites the other slot's header
 * with a higher serial, so the next boot selects it.
 *
 * This is a read/modify tool for the two firmware-slot MTD partitions of the
 * device it runs on. It never touches bootloader, tags or config partitions.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <mtd/mtd-user.h>

#define VER_HDR_SIZE	0x200
#define UBOOT_SIZE	0x180000
#define OUTER_HDR_SIZE	0x14

#define H_FW_SIZE	0x30
#define H_KERNEL_SIZE	0x34
#define H_KERNEL_FILEOFS 0x38
#define H_KERNEL_CRC	0x3c
#define H_FS_SIZE	0x40
#define H_FS_FILEOFS	0x44
#define H_FS_CRC	0x48
#define H_PRODUCT	0x6c
#define H_UBOOT_CRC	0x98
#define H_CRC		0xa4
#define H_INNER_MAGIC	0xf4
#define H_SLOT_START	0x1f0
#define H_SERIAL	0x1f4
#define H_NEW		0x1f8
#define H_CRC2		0x1fc

#define PRODUCT		"ZXSLC SR1010"

static const uint8_t outer_magic[16] = {
	0x99,0x99,0x99,0x99, 0x44,0x44,0x44,0x44,
	0x55,0x55,0x55,0x55, 0xaa,0xaa,0xaa,0xaa,
};
static const uint8_t inner_magic[16] = {
	0x33,0x33,0x33,0x33, 0x66,0x66,0x66,0x66,
	0x99,0x99,0x99,0x99, 0xcc,0xcc,0xcc,0xcc,
};

/* The two firmware slots, by absolute offset in the whole flash. */
static const uint32_t slot_start[2] = { 0x600000, 0x2f00000 };

static uint32_t crc_table[256];

static void crc_init(void)
{
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = (c & 1) ? 0xedb88320u ^ (c >> 1) : c >> 1;
		crc_table[i] = c;
	}
}

static uint32_t crc32(const void *buf, size_t len)
{
	const uint8_t *p = buf;
	uint32_t c = 0xffffffffu;

	while (len--)
		c = crc_table[(c ^ *p++) & 0xff] ^ (c >> 8);
	return c ^ 0xffffffffu;
}

static uint32_t rd32(const uint8_t *p, size_t ofs)
{
	return p[ofs] | p[ofs + 1] << 8 | p[ofs + 2] << 16 |
	       (uint32_t)p[ofs + 3] << 24;
}

static void wr32(uint8_t *p, size_t ofs, uint32_t v)
{
	p[ofs] = v; p[ofs + 1] = v >> 8;
	p[ofs + 2] = v >> 16; p[ofs + 3] = v >> 24;
}

static void die(const char *msg)
{
	fprintf(stderr, "zte-fwslot: %s: %s\n", msg, strerror(errno));
	exit(1);
}

/* Read a sysfs attribute of an MTD device as an unsigned value. */
static long mtd_sysfs_u(int index, const char *attr)
{
	char path[64], buf[32];
	int fd, n;

	snprintf(path, sizeof(path), "/sys/class/mtd/mtd%d/%s", index, attr);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = 0;
	return strtol(buf, NULL, 0);
}

/* Find the MTD partition that starts at the given absolute flash offset. */
static int mtd_find_by_offset(uint32_t offset)
{
	DIR *d = opendir("/sys/class/mtd");
	struct dirent *e;
	int found = -1;

	if (!d)
		die("open /sys/class/mtd");
	while ((e = readdir(d))) {
		int idx;

		if (sscanf(e->d_name, "mtd%d", &idx) != 1)
			continue;
		if (strchr(e->d_name, 'r'))	/* skip mtdNro aliases */
			continue;
		if (mtd_sysfs_u(idx, "offset") == (long)offset) {
			found = idx;
			break;
		}
	}
	closedir(d);
	return found;
}

struct mtd {
	int fd;
	struct mtd_info_user info;
};

static void mtd_open(struct mtd *m, int index, bool writable)
{
	char path[32];

	snprintf(path, sizeof(path), "/dev/mtd%d", index);
	m->fd = open(path, writable ? O_RDWR : O_RDONLY);
	if (m->fd < 0)
		die(path);
	if (ioctl(m->fd, MEMGETINFO, &m->info) < 0)
		die("MEMGETINFO");
}

static bool mtd_bad(struct mtd *m, uint64_t ofs)
{
	long long o = ofs;

	return ioctl(m->fd, MEMGETBADBLOCK, &o) > 0;
}

static int mtd_erase(struct mtd *m, uint64_t ofs)
{
	struct erase_info_user e = { .start = ofs, .length = m->info.erasesize };

	ioctl(m->fd, MEMUNLOCK, &e);
	return ioctl(m->fd, MEMERASE, &e);
}

static void mtd_read(struct mtd *m, uint64_t ofs, void *buf, size_t len)
{
	if (lseek(m->fd, ofs, SEEK_SET) < 0 || read(m->fd, buf, len) != (ssize_t)len)
		die("mtd read");
}

/*
 * Scan a slot for its version header. The header is a single block carrying
 * the inner magic at +0xf4 and a CRC over [0:0xa4] at +0xa4. Returns the
 * block offset within the slot, or -1, and fills *serial when found.
 */
static long slot_scan(struct mtd *m, uint32_t *serial)
{
	uint8_t hdr[VER_HDR_SIZE];
	uint32_t bs = m->info.erasesize;

	for (uint64_t ofs = 0; ofs + VER_HDR_SIZE <= m->info.size; ofs += bs) {
		if (mtd_bad(m, ofs))
			continue;
		mtd_read(m, ofs, hdr, sizeof(hdr));
		if (memcmp(hdr + H_INNER_MAGIC, inner_magic, 16))
			continue;
		if (crc32(hdr, H_CRC) != rd32(hdr, H_CRC))
			continue;
		if (serial)
			*serial = rd32(hdr, H_SERIAL);
		return ofs;
	}
	return -1;
}

/* Highest serial across both slots, 0 if neither has a valid header. */
static uint32_t max_serial(void)
{
	uint32_t best = 0;

	for (int s = 0; s < 2; s++) {
		int idx = mtd_find_by_offset(slot_start[s]);
		struct mtd m;
		uint32_t serial;

		if (idx < 0)
			continue;
		mtd_open(&m, idx, false);
		if (slot_scan(&m, &serial) >= 0 && serial > best)
			best = serial;
		close(m.fd);
	}
	return best;
}

/* Map the package file and verify the CRCs the bootloader checks. */
struct package {
	uint8_t *data;
	size_t size;
	const uint8_t *hdr;	/* version header */
	const uint8_t *body;
	uint32_t body_len;
};

static void package_load(struct package *p, const char *path)
{
	FILE *f = fopen(path, "rb");
	long size;
	uint32_t hdr_ofs, body_ofs;

	if (!f)
		die(path);
	fseek(f, 0, SEEK_END);
	size = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (size < OUTER_HDR_SIZE + VER_HDR_SIZE)
		errno = EINVAL, die("package too small");
	p->data = malloc(size);
	if (!p->data || fread(p->data, 1, size, f) != (size_t)size)
		die("read package");
	fclose(f);
	p->size = size;

	if (memcmp(p->data, outer_magic, 16))
		errno = EINVAL, die("not an SR1010 upgrade package");
	hdr_ofs = 0x14 + rd32(p->data, 0x10);
	body_ofs = hdr_ofs + VER_HDR_SIZE;
	if (body_ofs > p->size)
		errno = EINVAL, die("truncated header");
	p->hdr = p->data + hdr_ofs;
	p->body = p->data + body_ofs;
	p->body_len = p->size - body_ofs;

	if (memcmp(p->hdr + H_INNER_MAGIC, inner_magic, 16))
		errno = EINVAL, die("bad version header");
	if (crc32(p->hdr, H_CRC) != rd32(p->hdr, H_CRC) ||
	    crc32(p->hdr, H_CRC2) != rd32(p->hdr, H_CRC2))
		errno = EINVAL, die("header CRC mismatch");
	if (strncmp((const char *)p->hdr + H_PRODUCT, PRODUCT, sizeof(PRODUCT) - 1))
		errno = EINVAL, die("package is not for this product");
	if (rd32(p->hdr, H_FW_SIZE) != p->body_len)
		errno = EINVAL, die("body size mismatch");

	uint32_t koff = rd32(p->hdr, H_KERNEL_FILEOFS);
	uint32_t ksz = rd32(p->hdr, H_KERNEL_SIZE);
	uint32_t foff = rd32(p->hdr, H_FS_FILEOFS);
	uint32_t fsz = rd32(p->hdr, H_FS_SIZE);

	if ((uint64_t)koff + ksz > p->size || (uint64_t)foff + fsz > p->size)
		errno = EINVAL, die("region outside package");
	if (crc32(p->body, UBOOT_SIZE) != rd32(p->hdr, H_UBOOT_CRC))
		errno = EINVAL, die("U-Boot CRC mismatch");
	if (crc32(p->data + koff, ksz) != rd32(p->hdr, H_KERNEL_CRC))
		errno = EINVAL, die("kernel CRC mismatch");
	if (crc32(p->data + foff, fsz) != rd32(p->hdr, H_FS_CRC))
		errno = EINVAL, die("rootfs CRC mismatch");
}

/*
 * Write one full erase block at or after @ofs, skipping bad blocks, and return
 * the offset after it. The slot is erased beforehand and @buf must hold a full
 * erase block, padded with 0xff by the caller.
 */
static uint64_t write_block(struct mtd *m, uint64_t ofs, const uint8_t *buf)
{
	uint32_t bs = m->info.erasesize;

	while (ofs < m->info.size) {
		if (mtd_bad(m, ofs)) {
			fprintf(stderr, "  skip bad block at %#llx\n",
				(unsigned long long)ofs);
			ofs += bs;
			continue;
		}
		if (lseek(m->fd, ofs, SEEK_SET) < 0 ||
		    write(m->fd, buf, bs) != (ssize_t)bs) {
			fprintf(stderr, "  write failed at %#llx, skipping\n",
				(unsigned long long)ofs);
			ofs += bs;
			continue;
		}
		return ofs + bs;
	}
	errno = ENOSPC;
	die("ran out of good blocks");
	return 0;
}

/*
 * Erase every good block of the slot, as the vendor flasher does. A header left
 * behind by an older firmware would otherwise still look valid to the
 * bootloader and take precedence over the new one.
 */
static void erase_slot(struct mtd *m)
{
	uint32_t bs = m->info.erasesize;

	for (uint64_t ofs = 0; ofs < m->info.size; ofs += bs) {
		if (mtd_bad(m, ofs))
			continue;
		if (mtd_erase(m, ofs) < 0)
			fprintf(stderr, "  erase failed at %#llx\n",
				(unsigned long long)ofs);
	}
}

static int cmd_check(const char *path)
{
	struct package p;

	package_load(&p, path);
	free(p.data);
	fprintf(stderr, "ok: valid SR1010 package for %s\n", PRODUCT);
	return 0;
}

static int cmd_flash(const char *path)
{
	struct package p;
	int target_slot, idx;
	struct mtd m;
	uint8_t hdr[VER_HDR_SIZE];
	uint32_t bs, serial;
	uint64_t ofs, left;
	const uint8_t *src;
	long so = -1;
	FILE *f;

	package_load(&p, path);

	/* Current slot comes from the bootinfo driver; flash the other one. */
	f = fopen("/sys/firmware/zx279133/slot_offset", "r");
	if (f) { if (fscanf(f, "%li", &so) != 1) so = -1; fclose(f); }
	target_slot = (so == (long)slot_start[1]) ? 0 : 1;

	idx = mtd_find_by_offset(slot_start[target_slot]);
	if (idx < 0)
		errno = ENODEV, die("target slot partition not found");
	mtd_open(&m, idx, true);
	bs = m.info.erasesize;
	if (p.body_len > m.info.size - bs)
		errno = ENOSPC, die("package larger than slot");

	serial = max_serial() + 1;
	memcpy(hdr, p.hdr, VER_HDR_SIZE);
	wr32(hdr, H_SLOT_START, slot_start[target_slot]);
	wr32(hdr, H_SERIAL, serial);
	wr32(hdr, H_NEW, 1);
	/* H_CRC covers [0:0xa4] and is unaffected; H_CRC2 covers the serial. */
	wr32(hdr, H_CRC2, crc32(hdr, H_CRC2));

	fprintf(stderr, "flashing slot %d (mtd%d), serial %u, body %#x\n",
		target_slot, idx, serial, p.body_len);

	erase_slot(&m);

	ofs = 0;
	left = p.body_len;
	src = p.body;
	while (left) {
		uint8_t pad[0x20000];
		const uint8_t *chunk = src;

		if (left < bs) {
			memset(pad, 0xff, bs);
			memcpy(pad, src, left);
			chunk = pad;
		}
		ofs = write_block(&m, ofs, chunk);
		if (left < bs)
			left = 0;
		else
			left -= bs;
		src += bs;
	}
	/* Version header goes in the next good block after the body. */
	{
		uint8_t hdrblk[0x20000];

		memset(hdrblk, 0xff, sizeof(hdrblk));
		memcpy(hdrblk, hdr, VER_HDR_SIZE);
		ofs = write_block(&m, ofs, hdrblk);
	}

	/* Verify the header reads back with a valid CRC. */
	if (slot_scan(&m, &serial) < 0)
		errno = EIO, die("header verify failed after flash");

	close(m.fd);
	free(p.data);
	fprintf(stderr, "ok: slot %d now holds serial %u; reboot to run it\n",
		target_slot, serial);
	return 0;
}

static int cmd_switch(void)
{
	long so = -1;
	FILE *f = fopen("/sys/firmware/zx279133/slot_offset", "r");
	int cur_slot, other, idx;
	struct mtd m;
	long hpos;
	uint32_t serial;
	uint8_t hdr[VER_HDR_SIZE];

	if (f) { if (fscanf(f, "%li", &so) != 1) so = -1; fclose(f); }
	cur_slot = (so == (long)slot_start[1]) ? 1 : 0;
	other = cur_slot ^ 1;

	idx = mtd_find_by_offset(slot_start[other]);
	if (idx < 0)
		errno = ENODEV, die("other slot partition not found");
	mtd_open(&m, idx, true);

	hpos = slot_scan(&m, &serial);
	if (hpos < 0)
		errno = ENODATA, die("other slot has no valid firmware");

	mtd_read(&m, hpos, hdr, sizeof(hdr));
	wr32(hdr, H_SERIAL, max_serial() + 1);
	wr32(hdr, H_CRC2, crc32(hdr, H_CRC2));

	/* NAND takes whole pages only: rewrite the full block, padded with 0xff. */
	{
		uint8_t blk[0x20000];

		memset(blk, 0xff, sizeof(blk));
		memcpy(blk, hdr, VER_HDR_SIZE);
		if (mtd_erase(&m, hpos) < 0)
			die("erase header block");
		if (lseek(m.fd, hpos, SEEK_SET) < 0 ||
		    write(m.fd, blk, m.info.erasesize) != (ssize_t)m.info.erasesize)
			die("write header");
	}

	close(m.fd);
	fprintf(stderr, "ok: next boot selects slot %d (serial %u)\n",
		other, rd32(hdr, H_SERIAL));
	return 0;
}

static int cmd_info(void)
{
	long so = -1;
	FILE *f = fopen("/sys/firmware/zx279133/slot_offset", "r");

	if (f) { if (fscanf(f, "%li", &so) != 1) so = -1; fclose(f); }
	printf("running slot offset: %#lx\n", so);
	for (int s = 0; s < 2; s++) {
		int idx = mtd_find_by_offset(slot_start[s]);
		struct mtd m;
		uint32_t serial;
		long hpos;

		printf("slot %d: start %#x mtd%d", s, slot_start[s], idx);
		if (idx < 0) { printf(" (missing)\n"); continue; }
		mtd_open(&m, idx, false);
		hpos = slot_scan(&m, &serial);
		if (hpos < 0)
			printf(" (no valid firmware)\n");
		else
			printf(" header@%#lx serial=%u%s\n", hpos, serial,
			       so == (long)slot_start[s] ? " [running]" : "");
		close(m.fd);
	}
	return 0;
}

int main(int argc, char **argv)
{
	crc_init();
	if (argc == 3 && !strcmp(argv[1], "flash"))
		return cmd_flash(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "check"))
		return cmd_check(argv[2]);
	if (argc == 2 && !strcmp(argv[1], "switch"))
		return cmd_switch();
	if (argc == 2 && !strcmp(argv[1], "info"))
		return cmd_info();

	fprintf(stderr,
		"usage: zte-fwslot check <package.bin>  verify a package without writing\n"
		"       zte-fwslot flash <package.bin>  write package to the inactive slot\n"
		"       zte-fwslot switch              select the other slot on next boot\n"
		"       zte-fwslot info                show both slots\n");
	return 1;
}

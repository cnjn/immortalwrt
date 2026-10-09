// SPDX-License-Identifier: GPL-2.0-only
/*
 * w25ntest v2 - what a SPI NAND with on-die ECC does to a page whose data and spare
 * bytes are programmed in two steps (the way JFFS2 writes its clean marker).
 *
 * Datasheet of the Winbond W25N01KV, 7.2.4: with ECC on, the parity of a 512 byte
 * sector covers the sector and the paired "User Data I" (spare bytes 4..15 of its
 * 16 byte group; bytes 0..3, "User Data II", are not protected). The sector and its
 * User Data I have to be programmed at one time.
 *
 * Usage:  w25ntest /dev/mtdN --list
 *         w25ntest /dev/mtdN BLOCK --yes [--sweep]
 *
 * It erases BLOCK, programs nine pages of it in different ways (all with the same data),
 * reads each back with the ECC on and again raw, and erases BLOCK again. It refuses a
 * device that is mounted, a bad block, or a block whose data area is not all 0xff.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <mtd/mtd-abi.h>

#define MAXPAGE 4096
#define MAXOOB  256
#define NSC     9

static int fd;
static struct mtd_info_user mi;
static int mtdnum = -1;

struct rd {
	int err;			/* errno of the ioctl, 0 if none */
	int returned;			/* the data buffer was filled */
	struct mtd_read_req_ecc_stats st;
	unsigned char data[MAXPAGE];
	unsigned char oob[MAXOOB];
};

static void die(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(1);
}

static uint64_t blk_off(unsigned blk)
{
	return (uint64_t)blk * mi.erasesize;
}

static int read_req(uint64_t off, int want_data, unsigned ooblen, int mode, struct rd *r)
{
	struct mtd_read_req q;
	int rc;

	memset(&q, 0, sizeof(q));
	memset(r, 0, sizeof(*r));
	memset(r->data, 0xa5, sizeof(r->data));		/* a sentinel: is the buffer filled on an error? */
	q.start = off;
	q.len = want_data ? mi.writesize : 0;
	q.ooblen = ooblen;
	q.usr_data = want_data ? (uintptr_t)r->data : 0;
	q.usr_oob = ooblen ? (uintptr_t)r->oob : 0;
	q.mode = mode;
	rc = ioctl(fd, MEMREAD, &q);
	if (rc < 0)
		r->err = errno;
	r->st = q.ecc_stats;
	if (rc < 0 && r->err == EBADMSG && !r->st.uncorrectable_errors)
		r->st.uncorrectable_errors = 1;
	if (want_data) {
		for (unsigned i = 0; i < mi.writesize; i++)
			if (r->data[i] != 0xa5) {
				r->returned = 1;
				break;
			}
	}
	return rc;
}

static int write_oob_only(uint64_t page_off, unsigned oobofs, const unsigned char *buf, unsigned len)
{
	struct mtd_oob_buf ob;

	ob.start = (uint32_t)(page_off + oobofs);
	ob.length = len;
	ob.ptr = (unsigned char *)buf;
	return ioctl(fd, MEMWRITEOOB, &ob);
}

static int write_data_only(uint64_t page_off, const unsigned char *buf)
{
	return pwrite(fd, buf, mi.writesize, page_off) == (ssize_t)mi.writesize ? 0 : -1;
}

static int write_both_auto(uint64_t page_off, const unsigned char *buf, const unsigned char *oob, unsigned ooblen)
{
	struct mtd_write_req w;

	memset(&w, 0, sizeof(w));
	w.start = page_off;
	w.len = mi.writesize;
	w.ooblen = ooblen;
	w.usr_data = (uintptr_t)buf;
	w.usr_oob = (uintptr_t)oob;
	w.mode = MTD_OPS_AUTO_OOB;
	return ioctl(fd, MEMWRITE, &w);
}

static int write_oob_auto(uint64_t page_off, const unsigned char *oob, unsigned ooblen)
{
	struct mtd_write_req w;

	memset(&w, 0, sizeof(w));
	w.start = page_off;
	w.ooblen = ooblen;
	w.usr_oob = (uintptr_t)oob;
	w.mode = MTD_OPS_AUTO_OOB;
	return ioctl(fd, MEMWRITE, &w);
}

static int erase_block(unsigned blk)
{
	struct erase_info_user e = { .start = blk_off(blk), .length = mi.erasesize };

	return ioctl(fd, MEMERASE, &e);
}

static int is_bad(unsigned blk)
{
	long long off = blk_off(blk);

	return ioctl(fd, MEMGETBADBLOCK, &off) > 0;
}

static unsigned char *blockbuf;

/* 1 if the data area of the block reads as all 0xff */
static int block_data_empty(unsigned blk)
{
	if (pread(fd, blockbuf, mi.erasesize, blk_off(blk)) != (ssize_t)mi.erasesize)
		return -1;
	for (unsigned i = 0; i < mi.erasesize; i++)
		if (blockbuf[i] != 0xff)
			return 0;
	return 1;
}

/* the device is in use if a file system sits on it */
static int mounted(void)
{
	char name[64] = "", line[512], pat1[64], pat2[64], pat3[64];
	FILE *f = fopen("/proc/mtd", "r");
	int hit = 0;

	if (f) {
		while (fgets(line, sizeof(line), f)) {
			int n;
			char nm[64];

			if (sscanf(line, "mtd%d: %*x %*x \"%63[^\"]\"", &n, nm) == 2 && n == mtdnum)
				snprintf(name, sizeof(name), "%s", nm);
		}
		fclose(f);
	}
	snprintf(pat1, sizeof(pat1), "/dev/mtdblock%d ", mtdnum);
	snprintf(pat2, sizeof(pat2), "mtd%d ", mtdnum);
	snprintf(pat3, sizeof(pat3), "mtd:%s ", name);
	f = fopen("/proc/mounts", "r");
	if (!f)
		return 0;
	while (fgets(line, sizeof(line), f)) {
		if (strstr(line, pat1) || (name[0] && strstr(line, pat3)) ||
		    (!strncmp(line, "mtd", 3) && strstr(line, pat2)))
			hit = 1;
	}
	fclose(f);
	return hit;
}

static void pattern(unsigned char *buf, unsigned len, uint32_t seed)
{
	uint32_t x = seed * 2654435761u + 12345;

	for (unsigned i = 0; i < len; i++) {
		x ^= x << 13; x ^= x >> 17; x ^= x << 5;
		buf[i] = x & 0xff;
	}
}

static const char *errname(int e)
{
	switch (e) {
	case 0: return "none";
	case EBADMSG: return "EBADMSG (uncorrectable)";
	case EUCLEAN: return "EUCLEAN (bitflips, corrected)";
	default: return strerror(e);
	}
}

static void hexline(const char *tag, const unsigned char *b, unsigned from, unsigned to)
{
	printf("      %-14s", tag);
	for (unsigned i = from; i < to; i++)
		printf("%02x%s", b[i], (i + 1 - from) % 8 == 0 && i + 1 < to ? " " : "");
	printf("\n");
}

static const unsigned char cm8[8] = { 0x85, 0x19, 0x03, 0x20, 0x08, 0x00, 0x00, 0x00 };

enum {
	K_DATA, K_BOTH, K_OOB_THEN_DATA_AUTO, K_VENDOR, K_UD2, K_SPARE1, K_DATA_THEN_OOB, K_TWO_BYTES, K_OOB_ONLY,
};

struct sc {
	const char *name;
	const char *text;
	int kind;
	int reference;		/* no data is written: not judged */
};

static const struct sc scs[NSC] = {
	{ "S0", "control: the data in one program, no spare bytes", K_DATA, 0 },
	{ "S1", "the data and the 8 clean marker bytes (AUTO, our kernel: spare 2..9) in ONE program", K_BOTH, 0 },
	{ "S2", "the old JFFS2 way: clean marker (AUTO, spare 2..9) first, the data next", K_OOB_THEN_DATA_AUTO, 0 },
	{ "S3", "the vendor way: clean marker at spare 2..7 and 18..19 first, the data next", K_VENDOR, 0 },
	{ "S4", "clean marker only in unprotected User Data II (spare 2..3, 16..19, 32..33) first, the data next", K_UD2, 0 },
	{ "S5", "clean marker in the User Data I of sector 1 (spare 20..27) first, the data next", K_SPARE1, 0 },
	{ "S6", "the data first, the clean marker (AUTO, spare 2..9) next", K_DATA_THEN_OOB, 0 },
	{ "S7", "spare 2..3 only (User Data II) first, the data next", K_TWO_BYTES, 0 },
	{ "S8", "reference: the clean marker (AUTO, spare 2..9) alone, no data", K_OOB_ONLY, 1 },
};

struct result {
	int prog_err;
	/* read with the ECC on */
	int ecc_have_data, ecc_err;
	unsigned ecc_unc, ecc_cor, ecc_diff, ecc_first;
	unsigned cm_unc, cm_cor;
	/* read without the ECC: what the cells hold */
	unsigned raw_diff, raw_first, raw_ff, raw_sector[4];
	unsigned char oob[MAXOOB];
	int ooblen;
};

static unsigned diffcount(const unsigned char *a, const unsigned char *b, unsigned n, unsigned *first)
{
	unsigned d = 0;

	*first = 0;
	for (unsigned i = 0; i < n; i++)
		if (a[i] != b[i]) {
			if (!d)
				*first = i;
			d++;
		}
	return d;
}

static int run_scenario(unsigned blk, unsigned pg, const struct sc *s, struct result *res)
{
	uint64_t po = blk_off(blk) + (uint64_t)pg * mi.writesize;
	static unsigned char data[MAXPAGE];
	unsigned char o[40];
	unsigned oobn = mi.oobsize < MAXOOB ? mi.oobsize : MAXOOB;
	struct rd r;
	int rc = 0;

	memset(res, 0, sizeof(*res));
	pattern(data, mi.writesize, 12345);		/* the same data in every page */

	switch (s->kind) {
	case K_DATA:
		rc = write_data_only(po, data);
		break;
	case K_BOTH:
		rc = write_both_auto(po, data, cm8, 8);
		break;
	case K_OOB_THEN_DATA_AUTO:
		rc = write_oob_auto(po, cm8, 8);
		if (!rc)
			rc = write_data_only(po, data);
		break;
	case K_VENDOR:
		memset(o, 0xff, sizeof(o));
		memcpy(o, cm8, 6);		/* spare 2..7 */
		o[16] = 0x00; o[17] = 0x00;	/* spare 18..19 */
		rc = write_oob_only(po, 2, o, 18);
		if (!rc)
			rc = write_data_only(po, data);
		break;
	case K_UD2:
		memset(o, 0xff, sizeof(o));
		o[0] = 0x85; o[1] = 0x19;			/* spare 2..3 */
		o[14] = 0x03; o[15] = 0x20; o[16] = 0x08; o[17] = 0x00;	/* spare 16..19 */
		o[30] = 0x00; o[31] = 0x00;			/* spare 32..33 */
		rc = write_oob_only(po, 2, o, 32);
		if (!rc)
			rc = write_data_only(po, data);
		break;
	case K_SPARE1:
		rc = write_oob_only(po, 20, cm8, 8);
		if (!rc)
			rc = write_data_only(po, data);
		break;
	case K_DATA_THEN_OOB:
		rc = write_data_only(po, data);
		if (!rc)
			rc = write_oob_auto(po, cm8, 8);
		break;
	case K_TWO_BYTES:
		rc = write_oob_only(po, 2, cm8, 2);
		if (!rc)
			rc = write_data_only(po, data);
		break;
	case K_OOB_ONLY:
		rc = write_oob_auto(po, cm8, 8);
		memset(data, 0xff, mi.writesize);	/* what the cells should hold */
		break;
	}
	if (rc) {
		res->prog_err = errno ? errno : 1;
		return -1;
	}

	/* the ECC on */
	read_req(po, 1, oobn, MTD_OPS_PLACE_OOB, &r);
	res->ecc_unc = r.st.uncorrectable_errors;
	res->ecc_cor = r.st.corrected_bitflips;
	res->ecc_err = r.err;
	res->ecc_have_data = r.returned;
	if (res->ecc_have_data)
		res->ecc_diff = diffcount(r.data, data, mi.writesize, &res->ecc_first);
	/* the way JFFS2 checks the clean marker: 8 spare bytes, nothing else */
	read_req(po, 0, 8, MTD_OPS_AUTO_OOB, &r);
	res->cm_unc = r.st.uncorrectable_errors;
	res->cm_cor = r.st.corrected_bitflips;
	/* the ECC off: the cells as they are */
	read_req(po, 1, oobn, MTD_OPS_RAW, &r);
	res->ooblen = oobn;
	memcpy(res->oob, r.oob, oobn);
	if (!r.err) {
		res->raw_diff = diffcount(r.data, data, mi.writesize, &res->raw_first);
		for (unsigned i = 0; i < mi.writesize; i++) {
			if (r.data[i] == 0xff)
				res->raw_ff++;
			if (r.data[i] != data[i] && i / 512 < 4)
				res->raw_sector[i / 512]++;
		}
	} else {
		res->raw_diff = (unsigned)-1;
	}
	return 0;
}


/* many different data in many pages: how often does each way of writing the clean marker do harm? */
static void sweep(unsigned blk)
{
	static const char *const style[3] = {
		"the old JFFS2 way: clean marker (AUTO, spare 2..9) first, the data next",
		"the vendor way: clean marker at spare 2..7 and 18..19 first, the data next",
		"control: the data and the clean marker in ONE program",
	};
	static const char *const cls[6] = {
		"ok, no damage seen", "damaged, the ECC corrected it", "uncorrectable (EBADMSG)",
		"WRONG DATA read back (the chip reported success or a corrected bitflip)", "another read error", "cells differ from what was written",
	};
	static unsigned char data[MAXPAGE], o[40];
	unsigned cnt[3][6], npg[3] = { 0, 0, 0 };
	unsigned npages = mi.erasesize / mi.writesize;

	memset(cnt, 0, sizeof(cnt));
	if (npages > 63)
		npages = 63;
	if (erase_block(blk) < 0)
		die("erase");
	for (unsigned pg = 0; pg < npages; pg++) {
		int st = pg % 3, c, rc;
		uint64_t po = blk_off(blk) + (uint64_t)pg * mi.writesize;
		struct rd r;

		pattern(data, mi.writesize, 1000 + pg);
		if (st == 0) {
			rc = write_oob_auto(po, cm8, 8);
			if (!rc)
				rc = write_data_only(po, data);
		} else if (st == 1) {
			memset(o, 0xff, sizeof(o));
			memcpy(o, cm8, 6);
			o[16] = 0x00; o[17] = 0x00;
			rc = write_oob_only(po, 2, o, 18);
			if (!rc)
				rc = write_data_only(po, data);
		} else {
			rc = write_both_auto(po, data, cm8, 8);
		}
		if (rc) {
			printf("page %u: the write failed: %s\n", pg, strerror(errno));
			continue;
		}
		npg[st]++;
		read_req(po, 1, mi.oobsize < MAXOOB ? mi.oobsize : MAXOOB, MTD_OPS_RAW, &r);
		if (r.err || memcmp(r.data, data, mi.writesize)) {
			c = 5;
		} else {
			read_req(po, 1, mi.oobsize < MAXOOB ? mi.oobsize : MAXOOB, MTD_OPS_PLACE_OOB, &r);
			if (r.err == EBADMSG || r.st.uncorrectable_errors)
				c = 2;
			else if (r.err == EUCLEAN || r.st.corrected_bitflips)
				c = (r.returned && memcmp(r.data, data, mi.writesize)) ? 3 : 1;
			else if (r.err)
				c = 4;
			else
				c = memcmp(r.data, data, mi.writesize) ? 3 : 0;
		}
		cnt[st][c]++;
	}
	printf("sweep: %u pages, a different data pattern in each\n", npg[0] + npg[1] + npg[2]);
	for (int st = 0; st < 3; st++) {
		printf("\n[%s]  (%u pages)\n", style[st], npg[st]);
		for (int c = 0; c < 6; c++)
			if (cnt[st][c])
				printf("   %-40s %u\n", cls[c], cnt[st][c]);
	}
}

static void usage(void)
{
	fprintf(stderr, "usage: w25ntest /dev/mtdN --list\n       w25ntest /dev/mtdN BLOCK --yes [--sweep]\n");
	exit(2);
}

int main(int argc, char **argv)
{
	unsigned nblk, blk, i;
	int yes = 0, list = 0, dosweep = 0;
	struct result res[NSC];
	int tested = 0;

	if (argc < 3 || sscanf(argv[1], "/dev/mtd%d", &mtdnum) != 1)
		usage();
	if (!strcmp(argv[2], "--list"))
		list = 1;
	else if (argc >= 4 && !strcmp(argv[3], "--yes")) {
		yes = 1;
		dosweep = argc >= 5 && !strcmp(argv[4], "--sweep");
	}
	else
		usage();

	fd = open(argv[1], O_RDWR);
	if (fd < 0)
		die("open");
	if (ioctl(fd, MEMGETINFO, &mi) < 0)
		die("MEMGETINFO");
	if (mi.type != MTD_NANDFLASH || !(mi.flags & MTD_WRITEABLE) || mi.writesize > MAXPAGE) {
		fprintf(stderr, "%s is not a writeable NAND with pages of at most %d bytes\n", argv[1], MAXPAGE);
		return 2;
	}
	nblk = mi.size / mi.erasesize;
	printf("%s: %u blocks of %u, page %u, spare %u\n", argv[1], nblk, mi.erasesize, mi.writesize, mi.oobsize);
	blockbuf = malloc(mi.erasesize);
	if (!blockbuf)
		die("malloc");

	if (list) {
		unsigned shown = 0;

		for (blk = nblk; blk-- > 0 && shown < 12;) {
			if (is_bad(blk) || block_data_empty(blk) != 1)
				continue;
			printf("  block %u (offset 0x%llx): the data area is empty\n", blk, (unsigned long long)blk_off(blk));
			shown++;
		}
		printf("(%u shown, from the end of the device; the spare area of such a block may still hold a clean marker)\n", shown);
		return 0;
	}

	blk = strtoul(argv[2], NULL, 0);
	if (blk >= nblk) {
		fprintf(stderr, "block %u is out of range\n", blk);
		return 2;
	}
	if (mounted()) {
		fprintf(stderr, "refused: %s has a file system mounted\n", argv[1]);
		return 2;
	}
	if (is_bad(blk)) {
		fprintf(stderr, "refused: block %u is bad\n", blk);
		return 2;
	}
	if (block_data_empty(blk) != 1) {
		fprintf(stderr, "refused: the data area of block %u is not empty\n", blk);
		return 2;
	}
	if (!yes)
		usage();
	if (blk < nblk / 2)
		printf("note: block %u is in the first half of the device; blocks from the end are the safest choice\n", blk);

	if (dosweep) {
		printf("block %u: sweep, erasing again at the end\n\n", blk);
		sweep(blk);
		goto done;
	}
	printf("block %u: erasing, writing %d test pages, erasing again\n\n", blk, NSC);
	if (erase_block(blk) < 0)
		die("erase");

	for (i = 0; i < NSC && i < mi.erasesize / mi.writesize; i++) {
		if (run_scenario(blk, i, &scs[i], &res[i]) < 0)
			printf("%s: the write failed: %s\n", scs[i].name, strerror(res[i].prog_err));
		else
			tested++;
	}

	for (i = 0; i < NSC; i++) {
		const char *v;

		if (res[i].prog_err) {
			printf("%s  %s\n      write error\n", scs[i].name, scs[i].text);
			continue;
		}
		if (scs[i].reference)
			v = "reference";
		else if (res[i].ecc_err == EBADMSG || res[i].ecc_unc || res[i].cm_unc || res[i].ecc_diff || res[i].raw_diff)
			v = "BROKEN";
		else if (res[i].ecc_err == EUCLEAN || res[i].ecc_cor || res[i].cm_cor)
			v = "DAMAGED, the ECC corrected it";
		else if (res[i].ecc_err)
			v = "UNKNOWN (the read failed)";
		else
			v = "ok";
		printf("%s  %s\n      -> %s\n", scs[i].name, scs[i].text, v);
		printf("      ECC on : result %s, uncorrectable %u, corrected %u, ", errname(res[i].ecc_err),
		       res[i].ecc_unc, res[i].ecc_cor);
		if (res[i].ecc_have_data)
			printf("data returned, %u bytes differ from what was written\n", res[i].ecc_diff);
		else
			printf("no data returned\n");
		printf("      JFFS2-style read of the 8 clean marker bytes: uncorrectable %u, corrected %u\n",
		       res[i].cm_unc, res[i].cm_cor);
		if (res[i].raw_diff == (unsigned)-1)
			printf("      ECC off: the raw read failed\n");
		else
			printf("      ECC off: the cells differ from what was written in %u bytes (per sector %u %u %u %u), %u of %u data bytes are 0xff\n",
			       res[i].raw_diff, res[i].raw_sector[0], res[i].raw_sector[1], res[i].raw_sector[2],
			       res[i].raw_sector[3], res[i].raw_ff, mi.writesize);
		hexline("spare 0..23", res[i].oob, 0, 24);
		if (res[i].ooblen > 64)
			hexline("spare 64..95", res[i].oob, 64, res[i].ooblen < 96 ? res[i].ooblen : 96);
	}

	/* S2 and S6: is the stored parity the AND of what S0 (data) and S8 (clean marker alone) store? */
	if (!res[0].prog_err && !res[8].prog_err && res[0].ooblen >= 96) {
		static const int chk[] = { 2, 6 };

		printf("\nparity check (spare 64..95, the bytes the chip writes itself):\n");
		for (i = 0; i < 2; i++) {
			int k = chk[i], and_ok = 1, one_ok = 1;

			if (res[k].prog_err)
				continue;
			for (int j = 64; j < 96; j++) {
				if (res[k].oob[j] != (res[0].oob[j] & res[8].oob[j]))
					and_ok = 0;
				if (res[k].oob[j] != res[1].oob[j])
					one_ok = 0;
			}
			printf("  %s: equal to (S0 AND S8) = the two programs are merged bit by bit: %s;  equal to S1 (one program, the right parity): %s\n",
			       scs[k].name, and_ok ? "yes" : "no", one_ok ? "yes" : "no");
		}
	}

done:
	if (erase_block(blk) < 0)
		fprintf(stderr, "\nWARNING: the final erase of block %u failed: %s\n", blk, strerror(errno));
	else if (block_data_empty(blk) != 1)
		fprintf(stderr, "\nWARNING: block %u does not read as empty after the final erase\n", blk);
	else
		printf("\nblock %u erased again%s\n", blk, dosweep ? "." : ", all scenarios ran.");
	return 0;
}

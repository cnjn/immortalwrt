w25ntest v3 - does programming the spare bytes and the data of a page in two steps break the on-die ECC of the SPI NAND?

Files
  w25ntest.c          source (GPL-2.0-only)
  w25ntest-aarch64    static binary for the router (musl, aarch64, stripped)

Background: Winbond W25N01KV datasheet Rev.A, 7.2.4. With ECC on, the parity of a 512 byte sector covers the sector
and its paired "User Data I" (the spare bytes 4..15 of the 16 byte group of that sector; bytes 0..3 are "User Data II" and
are not protected). The datasheet asks to program a sector and its User Data I at one time. JFFS2 writes the clean marker
into the spare area first and the data of the page later.

What it does
  /dev/mtdN --list         shows blocks whose data area is empty (nothing is written), from the end of the device
  /dev/mtdN BLOCK --yes [--sweep]
                           erases BLOCK, programs 9 of its pages in different ways (all with the same data), reads each
                           back with the ECC on and again raw (ECC off), prints what it found, erases BLOCK again
It refuses a device that is mounted, a bad block, and a block whose data area is not all 0xff.
It touches only that one block.

Which device and block
  Not the Plugin partition while the overlay is on it (refused), and not /dev/mtd2 (usercfg): read-only in the device
  tree on purpose, open() gives "Permission denied".
  Not the vendor firmware slot either: its image fills the whole slot (zte-fwslot info: header@0x28e0000 of 0x2900000);
  the only empty blocks there are the 0xff padding of the U-Boot area, and a failed test would leave garbage in it.
  Use the unused tail of the slot that holds ImmortalWrt: zte-fwslot info shows its header, for example header@0x26a0000;
  every block after the header block, up to the end of the slot (0x2900000), is not used by anything. Slot 0 is /dev/mtd4,
  slot 1 is /dev/mtd5. Take the block that --list shows first (the one nearest to the end of the device).

On the router
  cat w25ntest-aarch64 | ssh root@192.168.5.1 'cat > /tmp/w25ntest; chmod +x /tmp/w25ntest'      (from the PC)
  /tmp/w25ntest /dev/mtd4 --list
  /tmp/w25ntest /dev/mtd4 BLOCK --yes

The scenarios (the same data in every page)
  S0  data only, one program                                  control
  S1  data + 8 clean marker bytes (AUTO, spare 2..9), ONE program   control
  S2  clean marker (AUTO) first, data next                    the old JFFS2 way
  S3  clean marker at the vendor's bytes (spare 2..7 and 18..19) first, data next
  S4  clean marker only in unprotected User Data II, data next
  S5  clean marker in the User Data I of sector 1, data next
  S6  data first, clean marker (AUTO) next
  S7  spare 2..3 only first, data next
  S8  the clean marker alone, no data                         reference (gives the parity the clean marker produces)

How to read the output, per scenario
  ECC on : uncorrectable / corrected counts of a read of the whole page. "no data returned" means the kernel failed the
           read with EBADMSG (uncorrectable). Otherwise how many bytes differ from what was written.
  JFFS2-style read: the 8 spare bytes only, the way JFFS2 checks the clean marker.
  ECC off: what the cells really hold (raw read): how many bytes differ from what was written, per sector, and how many
           data bytes are still 0xff (all of them = the data was never programmed).
  spare 64..95: the parity the chip wrote itself.
  Last block: "parity check" for S2 and S6: is the stored parity the bit-by-bit AND of S0 (data alone) and S8 (marker alone)?
  If yes the chip merged the two programs, which is the mechanism of the datasheet.

First real result (v1, block 8 of /dev/mtd5): S0 S1 S4 S7 ok; S3 S5 S6 uncorrectable; S2 showed no ECC error but data that
differed from what was written (v1 could not tell why; v2 reads the cells raw).

--sweep (v3)
  Instead of the nine scenarios: writes 63 pages of the block, 21 for each of three ways (the old JFFS2 way, the vendor way,
  and the control with one program), every page with different data, reads each back raw and with the ECC on, and prints how
  many pages ended in each class: ok / damaged but the ECC corrected it / uncorrectable (EBADMSG) / WRONG DATA read back with no
  error / another read error / cells differ from what was written. It answers: how often does each way really do harm, and
  can the merged parity make the ECC return wrong data silently?
  /tmp/w25ntest /dev/mtd4 BLOCK --yes --sweep

Results so far (hardware, W25N01KV, our kernel, ECC on, /dev/mtd4 block 327, v2):
  S0 S1 S4 S7 ok.  S2 S3 S6 uncorrectable (EBADMSG).  S5: the read failed with an error that v2 did not name (v3 prints it).
  Raw reads: the cells always held the data that was written: the data is intact, only the parity is wrong.
  Parity check: for S2 and S6 the stored parity equals S0 AND S8 bit for bit, and differs from S1: the chip stores the AND of
  the parities of the two programs.
  v1 (a different data pattern in each page, block 8 of /dev/mtd5): S2 once read back different data with no ECC error;
  v3 --sweep shows why: the merged parity makes the ECC correct a good bit (S5: EUCLEAN, 1 bit corrected, 1 byte wrong).
  v3 (--sweep, /dev/mtd4 block 327, 21 pages each, different data in every page):
     old JFFS2 way: 15 uncorrectable, 6 wrong data;  vendor way: 13 uncorrectable, 8 wrong data;  one program: 21 ok.

The smoke test of the program ran against a model of the chip built from the datasheet (not against the chip).

Coexistence test: does the vendor firmware damage the files in the shared Plugin partition?

Why: with ECC on, a NAND page of the W25N01KV that gets its spare bytes and its data in two programs ends with a wrong ECC
parity (docs/jffs2-on-spi-nand.md). The vendor JFFS2 writes its clean marker into the spare area when it erases a block and the data
later, so a block it takes from its free list is damaged on page 0. This test makes the vendor system take many blocks and
checks what happens to its own files and to the files OpenWrt left in the same partition.

Before you start
  - Flash the final image (MANIFEST.txt) and erase the Plugin partition once (U-Boot: nand erase 5800000 2800000).
    Everything in Plugin is lost, including the OpenWrt settings (sysupgrade -b first if you want them).
  - The way back from the vendor system is to flash the OpenWrt image again from the vendor web page. zte-fwslot cannot be run
    on the vendor side and the vendor's own "switch" breaks the header (docs/vendor-slots.md).
  - On the vendor shell check that these exist: md5sum dd mount umount sync mkdir cp rm head tail (dd and md5sum are the ones
    that matter). /dev/urandom is needed too.

Steps
 1. ImmortalWrt:   sh owrt-prep.sh                 20 canary files in the overlay + a marker in system.description (to see whether the
                                                   settings survive); prints the md5 list: copy it off the router
 2. ImmortalWrt:   zte-fwslot switch               reboots into the vendor system
 3. vendor:        sh vendor-test.sh quick         (the whole output goes to /tmp/vendor-test.log, the summary is printed at the end)
                                                   10 MiB of random files, remount, check (the vendor mounts the partition itself,
                                                   otherwise the script does: mount -t jffs2 /dev/mtdblock9 /Plugin)
                   sh vendor-test.sh churn         the same, then 4 rounds of delete half / write 20 / remount / check: the vendor
                                                   erases and reuses blocks and garbage collects, which is where it can move the
                                                   OpenWrt files into damaged blocks
 4. vendor web page: flash the OpenWrt image       back to ImmortalWrt
 5. ImmortalWrt:   sh owrt-verify.sh               canary files, the vendor's files (/overlay/vtest), ECC counter, kernel messages

What the output means
  "REMOUNT FAILED" or "CANNOT MOUNT"          the vendor file system could not be mounted again: its own writes broke it
                                              (kernel messages: "cannot read OOB for EB at", error -74)
  "vendor files: N bad of M"                  files the vendor wrote and could not read back correctly (read error or a different md5)
  "canary: N bad of 20"                       files OpenWrt left that the vendor read or moved wrongly
  after the way back: "bad" in owrt-verify.sh  the damage as OpenWrt sees it
  "umount: ... in use"                        the vendor programs hold files in /Plugin; the script drops the caches instead of mounting again
                                              (the mount-time check of the vendor kernel is then not done)
  after the way back: the setting marker       if it is gone or different, the settings were overwritten (see docs/jffs2-on-spi-nand.md)
  all zero and no kernel messages             the vendor does not damage the partition in this test (not a proof for other loads)

DRYRUN=1 PLUGIN=/some/dir sh vendor-test.sh    runs the logic on a directory without mounting (that is how the scripts were tested)

# ZTE ZX279133 / ZXSLC SR1010

ImmortalWrt for the SR1010 in the **vendor upgrade package format**. The same
`.bin` installs from the vendor web interface, from LuCI (System, Backup / Flash
Firmware) and with `zte-fwslot`, and the router can start the vendor system and
ImmortalWrt in place of each other: the flash holds two firmware slots, and the
vendor bootloader starts the valid one with the highest serial number.

The target uses the prepared Linux 6.18.38 tree through
`CONFIG_EXTERNAL_KERNEL_TREE`.

## Images

```text
bin/targets/zte/zx279133/immortalwrt-zte-zx279133-zte_zxslc-sr1010-flash-squashfs-sysupgrade.bin
bin/targets/zte/zx279133/immortalwrt-zte-zx279133-zte_zxslc-sr1010-flash-squashfs-sysupgrade-stock-uboot.bin
```

Both hold the vendor U-Boot, the kernel (a FIT, lzma, encrypted the way the
vendor loader expects) and a plain squashfs root filesystem, behind the version
header with the CRCs the bootloader checks (`mkfw/sr1010-mkfw.py`).

* `sysupgrade.bin` carries a one-instruction patch of the vendor U-Boot of
  `V1.0.0.2B7.8000`. The vendor U-Boot copies the kernel into an 8 MiB heap
  before it decrypts it, so a kernel FIT above about 8.4 MB does not boot
  ("malloc tmp_kernel failed"). The patch moves that scratch buffer to
  unused RAM. `sr1010-mkfw.py` checks the original bytes and refuses any other
  U-Boot. This is the image to use.
* `sysupgrade-stock-uboot.bin` leaves the U-Boot untouched. It only boots while
  the kernel FIT stays below about 8 MB; the packer warns when it does not.

The vendor package is not part of this tree. The build reuses its U-Boot and
version header and needs the `V1.0.0.2B7.8000` release for the patched image.

## Build

The kernel tree must sit next to this one, because the network microcode is
built into the kernel from a path relative to the kernel tree:

```text
<dir>/immortalwrt
<dir>/linux-mainline-zte-zxslc-sr1010/linux-6.18.38
```

dae builds its eBPF programs with the host `clang`, which needs the BPF target,
so install clang and LLVM on the build host. Then, from the ImmortalWrt root:

```sh
./scripts/feeds update -a
./scripts/feeds install -a

SR1010_VENDOR_TEMPLATE=/absolute/path/to/vendor-upgrade.bin \
  ./scripts/configure-sr1010-flash.sh
make -j$(nproc)
```

`KERNEL_TREE=/absolute/path/to/linux-6.18.38` selects another kernel tree, as
long as the layout above is kept. The package selection is in
`configs/zte_zx279133_sr1010_squashfs.config`.

### Room in a slot

A slot is 41 MiB. The U-Boot, the kernel, the version header and spare blocks
for bad blocks take part of it; the rest is left for the root filesystem, and
the packer stops with an error when the image does not fit. Every package added
to the configuration has to be paid for out of that room. The squashfs uses
1 MiB blocks, which compress the large Go binaries (Tailscale, dae) better.

## Flash layout

| Partition | Use |
| --- | --- |
| slot 0, `0x600000`–`0x2f00000` | one firmware slot |
| slot 1, `0x2f00000`–`0x5800000` | the other firmware slot |
| `Plugin` | shared with the vendor firmware, which keeps its files there |

The root filesystem is a read-only squashfs. The overlay lives in the `.owrt`
directory of the `Plugin` partition (`/etc/fstools-shared-overlay`), next to the
vendor's files, which are never erased: a factory reset only deletes the files
of the overlay. When the firmware is replaced from elsewhere, for example the
vendor web interface, the overlay no longer matches the root filesystem; the
settings that sysupgrade keeps are rescued and the rest is dropped.

The `Plugin` partition is JFFS2 on a SPI-NAND with on-die ECC, where a page can
be programmed only once between erases. The kernel therefore keeps the JFFS2
clean markers in the data and not in the OOB; see
[docs/jffs2-on-spi-nand.md](docs/jffs2-on-spi-nand.md). If the overlay volume
still cannot be mounted, the router starts with an overlay in RAM and says so in
the log, instead of staying on the read-only root file system.

The vendor configuration partition stays read-only.

## Installing and switching

* LuCI, System, Backup / Flash Firmware, or `sysupgrade <image>`: writes the
  inactive slot and reboots into it.
* The vendor web interface accepts the same file: the package is unsigned, and
  the vendor flasher skips the signature check for that. On a device,
  ImmortalWrt boots afterwards, and the header the flasher wrote is intact:
  both CRCs are valid and it differs from the package header only in the slot
  start, the serial, the new-version flag and the CRC2 that covers them.
* System, Firmware Slots in LuCI, or `zte-fwslot switch`: makes the other slot
  the next boot, for example to return to the vendor system. The slot is
  checked against the CRCs of its header first: a slot the bootloader picks but
  cannot start is not replaced by the other one (seen with a kernel too large
  for the vendor U-Boot). `zte-fwslot info [-j]` shows both slots.

### Returning from the vendor system

How the slots and the version header work, and the evidence for what follows, is in
[docs/vendor-slots.md](docs/vendor-slots.md) (in Chinese).

Install the ImmortalWrt image again from the vendor web interface. It erases
the whole slot and writes a fresh header.

Do not use the vendor `fw_flashing -v switch`. It rewrites the version header of
the other slot in place, without erasing it first. NAND can only turn bits from
1 to 0, so what lands in flash is the old and the new bytes ANDed together. The
serial then does not get larger, the CRC2 no longer matches, and the tool
reports success all the same. Measured on a device, with the bytes predicted
beforehand:

| `0x1f4` to `0x1ff` of the ImmortalWrt header | |
| --- | --- |
| before | `1c 00 00 00 01 00 00 00 e4 9f 9e bd` |
| after `fw_flashing -v switch` (serial 30 to be written) | `1c 00 00 00 01 00 00 00 80 98 9a bd` |

Every later call then fails with `version header crc failed`. The bootloader only
checks the CRC1, so the slot still boots when it is selected, but it is no
longer selected. `zte-fwslot switch` erases the block and writes it whole.

## USB disks and extroot

USB storage mounts as usual (LuCI, System, Mount Points). extroot, which puts
the overlay on a USB disk, also works with the shared overlay: the overlay on
the disk is kept in its `.owrt` directory, like the internal one, so the
documented way to set it up applies unchanged. Format the disk as ext4, copy the
whole `/overlay` to it, and mount it with "Use as external overlay". The
configuration is read from `/overlay/.owrt/upper/etc/config/fstab`. extroot
has not been tried on a device.

## Defaults

LAN `192.168.5.1`; Chinese interface with the Argon theme and Beijing time;
IPv6; hardware flow offloading (falls back to software by itself); the two
hardware RX queues are used as they are, without software packet steering.

LAN and WAN use the same MAC address, as the factory firmware does. The hardware
NAT writes one source MAC, the WAN address, into every routed frame, so with a
separate LAN address the driver refuses all WAN-to-LAN flows and downloads stay
on the CPU (the first refusal is logged: `dmesg | grep "flow offload refused"`).

The status light is white while the WAN has working internet and red
otherwise (`sr1010-netled`, `/etc/config/sr1010-netled`). The five lights beside
the sockets follow the links of their ports.

The reset button is handled by `gpio-button-hotplug`: a short press reboots, and
holding it for five seconds restores the factory settings.

## Tests

`package/utils/zte-fwslot/test/run.sh` runs the unmodified `zte-fwslot` against
files that stand in for the two slots, including bad blocks, a block that
refuses a write and damaged slots. It needs the tool and the shim built for the
machine it runs on:

```sh
gcc -O2 -o zte-fwslot package/utils/zte-fwslot/src/zte-fwslot.c
gcc -shared -fPIC -o fakemtd.so package/utils/zte-fwslot/test/fakemtd.c -ldl
package/utils/zte-fwslot/test/run.sh ./zte-fwslot ./fakemtd.so \
  vendor-upgrade.bin immortalwrt-sysupgrade.bin /tmp/fwslot-test
```

## Network performance

Measured on the device with this image family, except where the kernel
repository is named:

* Receiving, several TCP flows from a host to the router: about 2.2 Gbit/s on
  a 2.5G LAN port, 94% of what TCP can carry on 2.5G, with both RX queues in
  use. The kernel repository records 2.35 Gbit/s on the WAN port.
* Routed and NAT traffic that the hardware flow offload takes does not use the
  CPU; the kernel repository records about 2.3 Gbit/s.
* TCP that the router sends itself: about 1.4 Gbit/s for one flow and 1.9 Gbit/s
  for four, with both cores busy. The driver has no scatter-gather and no TSO,
  and the hardware gather and the TSO template are not usable yet, so the CPU
  copies and segments every packet. Traffic that cannot be offloaded (dae,
  Tailscale, proxies) takes this path. The kernel repository records 1.75 to
  1.94 Gbit/s for this direction on earlier builds.

The LAN ports and the CPU port of the switch do not advertise pause, as the WAN
MAC does. With pause negotiated, an upload settled at about 0.95 Gbit/s with
some 25000 PAUSE frames per five seconds; with it off the same test reached
2.22 Gbit/s. `ethtool -A` cannot turn it on again.

## Status

Tried on a device: booting from a slot with the patched U-Boot, the network
ports and the LuCI interface of earlier builds; installing from the vendor web
interface; `zte-fwslot switch` from the command line to the vendor system; the
overlay in the Plugin partition, whose settings survive a reboot.
Not tried yet, because they were added later or need the other system: the
Firmware Slots page in LuCI, the reset button, the lights (the status light
following the WAN, the socket lights), extroot, the rescue of the overlay's
settings after the firmware was replaced from the vendor web interface, the
vendor firmware reading a Plugin partition written by this one, and hardware
flow offloading.

The tests above cover `zte-fwslot` against simulated flash, and the slot
headers the vendor flasher wrote in a flash dump pass its checks.

## RAM boot

`./scripts/configure-sr1010-initramfs.sh` builds a RAM-only U-Boot FIT
initramfs instead, which leaves the flash alone. Serve the ITB over TFTP, load
it to a safe address, then run `bootm` on that address. The kernel expands to
about 32 MiB at `0x80200000`, so `0x82000000` is too close; use a higher address
such as `0x88000000`:

```text
tftpboot 0x88000000 immortalwrt-zte-zx279133-zte_zxslc-sr1010-initramfs.itb
bootm 0x88000000
```

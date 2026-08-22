# ZTE ZX279133 / ZXSLC SR1010

This target currently produces a **RAM-only U-Boot FIT initramfs**. It does not
create a flashable factory or sysupgrade image. The board DTS deliberately keeps
SPI-NAND read-only.

The target uses the prepared Linux 6.18.38 tree through
`CONFIG_EXTERNAL_KERNEL_TREE` and embeds the ImmortalWrt root filesystem in the
arm64 `Image`. The FIT contains the gzip-compressed kernel and
`zx279133-sr1010.dtb`, both using load/entry address `0x80200000`.

## Build

From the ImmortalWrt root:

```sh
./scripts/configure-sr1010-initramfs.sh
make -j$(nproc)
```

To use a different prepared tree:

```sh
KERNEL_TREE=/absolute/path/to/linux-6.18.38 \
  ./scripts/configure-sr1010-initramfs.sh
```

The output is:

```text
bin/targets/zte/zx279133/immortalwrt-zte-zx279133-zte_zxslc-sr1010-initramfs.itb
```

## RAM boot

Serve the ITB over TFTP, load it to a safe U-Boot RAM address that does not
overlap the kernel destination, then run `bootm` on that address. The embedded
kernel expands to about 32 MiB at `0x80200000`, so `0x82000000` is too close.
Use a higher address such as `0x88000000`:

```text
tftpboot 0x88000000 immortalwrt-zte-zx279133-zte_zxslc-sr1010-initramfs.itb
bootm 0x88000000
```

The kernel itself is decompressed to and entered at `0x80200000`.

# SR1010 上的 JFFS2 与 SPI-NAND

ImmortalWrt 的持久 overlay 放在 `Plugin` 分区（JFFS2）的 `.owrt` 目录里。这份文档记录
在这块 NAND 上用 JFFS2 时遇到的一个问题、原因、怎么改的，以及改动对原厂系统共用 Plugin
有什么影响。每条结论标了来源：**实测**（在设备上测得）、**读码**（读内核源码得出）、
**推断**（由前两者推出，没有直接验证）。

## 1. 现象

**实测。** 把 Plugin 整个擦空，然后：

```sh
mount -t jffs2 /dev/mtdblock6 /tmp/t
dd if=/dev/urandom of=/tmp/t/a bs=1k count=300; sync
umount /tmp/t
mount -t jffs2 /dev/mtdblock6 /tmp/t      # 失败
```

```text
jffs2: cannot read OOB for EB at 02740000, requested 8 bytes, read 8 bytes, error -74
mount: mounting /dev/mtdblock6 on /tmp/t failed: I/O error
```

- `-74` 是 `-EBADMSG`，即 ECC 不可纠正；`/sys/class/mtd/mtd6/ecc_failures` 随之增加。
- 整个过程没有重启或断电。
- 扫描按块号递增进行：出错块之前扫过的块都读得出来，其中有只带清除标记的空块；出错的是第一个写过数据的块。
- 芯片是 Winbond W25N01KV（ID `ef ae 21`），页 2048 字节，OOB 96 字节，片上 ECC 开启。

失败之后 JFFS2 放弃整个挂载（读码：`fs/jffs2/scan.c` 在 `jffs2_check_nand_cleanmarker()`
返回错误时直接 `return ret`，只有位翻转 `-EUCLEAN` 被容忍）。上游 fstools 的 `mount_root`
又忽略挂载结果，于是系统停在只读的 squashfs 根上：没有 overlay，没有主机名，没有网络配置。
实际遇到的两次（擦空前的块 223，擦空后的块 318）都是这样。

## 2. 原因

**读码。** JFFS2 对 NAND 的做法是：每擦完一个块，把清除标记（cleanmarker）**单独**写进该块第 0
页的 OOB（`jffs2_write_nand_cleanmarker()`，只带 OOB、不带数据）。这个块第一次写数据时，
数据节点从块首开始，落在**同一页**上（`cleanmarker_size` 为 0）。于是第 0 页被编程了两次。

**推断。** 片上 ECC 在每次编程时按整页重新生成校验位。NAND 的位只能从 1 写成 0，所以
第二次写入的校验位会与第一次留下的按位相与，结果对不上数据，这一页之后读出来就是不可纠正的
ECC 错误。符合这个推断的事实：只被编程一次的页（空块上的清除标记）读得正常，出错的是
写过数据、也就是被编程过两次的块；改成每页只编程一次之后，同样的实验不再失败。

没有验证的部分：

- 没有这块芯片的数据手册，"校验位被合并"是由现象和片上 ECC 的一般做法推出的。
- 原厂系统用同一块闪存、同一类 JFFS2 并没有这个毛病，原因不明；没有去查原厂的 NAND 驱动。
- 为什么以前没出现：主线内核此前从没有向这块 NAND 写过东西
  （`SR1010_MTD_WRITE_ACCESS.md`：没有做过 program / erase / 文件系统写入测试），overlay 当时在内存里。

## 3. 改动

内核（提交 `0c3602121`，补丁 `kernel-patches/0008-*`）：

- `struct mtd_info` 增加 `program_once`：一个页在两次擦除之间只能编程一次。
  SPI-NAND 驱动在使用片上 ECC 时置位（`drivers/mtd/nand/spi/core.c`），分区继承它
  （`drivers/mtd/mtdpart.c`）。
- JFFS2 把原来的 `jffs2_cleanmarker_oob()` 拆成两个判断：`jffs2_nand()` 表示 NAND，
  `jffs2_cleanmarker_oob()` 表示 NAND 且 `!program_once`。坏块检查、扫描缓冲区、
  擦除失败处理对所有 NAND 照旧。
- `program_once` 的 NAND 上，清除标记是数据区里的一个节点，长度等于一页
  （`cleanmarker_size = writesize`），与带写缓冲的 NOR 用的是同一条老路径。第 0 页只编程一次，
  第一个数据节点从第 1 页开始，OOB 不再用来存清除标记。挂载时内核日志有一行：

  ```text
  jffs2: NAND pages can be programmed once: clean markers are in the data, 2048 bytes
  ```

- 每个块损失一页（2 KiB，占 128 KiB 的 1.6%）。
- 不使用片上 ECC 的 NAND 行为不变。
- JFFS2 的特性集与原厂内核一致：**不带 xattr（扩展属性），不带 summary（摘要）节点**，压缩只有 zlib 和 rtime
  （`target/linux/zte/zx279133/config-6.18`，原因见第 5 节）。
- 扫描（提交 `8aa6f4607`）：整页的清除标记比挂载时最先读的 1 KB 还长，扫描器读完标记就把这个块剩下的
  126 KiB 全部读一遍，320 个块约 39 MiB，在当时 25 MHz 单线的速度下挂载要约 16 s（**推断**，由挂载耗时和读速度
  算得）。现在块里除了清除标记什么都没有时，标记后面只多读 1 KB，按原来的规则认定整块干净；有数据的块走原来
  的完整扫描。

fstools（补丁 `203-overlay-ram-fallback.patch`）：overlay 卷挂不上时，`mount_overlay()` 回退到
内存 overlay 并打印 `cannot mount the overlay volume, using a temporary overlay in RAM`，
而不是停在只读根上。设置在这种情况下重启后不保留，但路由器带默认配置起来，
`192.168.5.1` 可以访问。

## 4. 验证

**实测**（改动之后）：擦空 Plugin，写入、卸载、重新挂载成功；设备重启后 overlay 挂在
`/dev/mtdblock6`，LuCI 里保存的设置在重启后保留。

没有做的：断电时的行为、长时间运行（垃圾回收、磨损）、改动之后回到原厂系统检查 Plugin。

**实测**（加上扫描改动之后，SFC 50 MHz 四线读）：挂载 Plugin 分区从日志里
`NAND pages can be programmed once` 到 `complete building xattr subsystem` 只用 0.24 s（原来约 16 s），
刷入新镜像后带着上一个镜像留下的真实数据也能正确挂载，"根文件系统变了、只保留设置"的救援路径走通。

## 5. 与原厂系统共用 Plugin

**实测（失败过一次）**：用带 xattr 的内核写过的 Plugin，原厂内核（5.4.196）挂载失败：

```text
jffs2: CLEANMARKER node found at 0x00000000 has totlen 0x800 != normal 0x0     （每个块一条，只是提示）
...
jffs2: Empty flash at 0x0164000c ends at 0x01640800
jffs2: Incompatible feature node (0xe008) found at offset 0x01642070
mount: mounting /dev/mtdblock9 on /Plugin failed: I/O error
```

- `0xe008` 是 xattr 节点。overlayfs 会往上层文件系统写扩展属性，JFFS2 带 xattr 支持就真的写了。
  原厂内核的 JFFS2 没有 xattr、没有 summary，只有 zlib 与 rtime 压缩（**读码**，原厂 kallsyms），
  遇到不兼容特性的节点就拒绝挂载。
- 整页的清除标记（长度 0x800）原厂只当提示，把块首的 12 字节记作垃圾空间，其余留空，扫描照常往下走；
  上面扫描过 178 个块都只有这条提示，直到第一个带数据的块才失败。
- 对策：我们内核的 JFFS2 与原厂同一套特性（不带 xattr、summary，压缩只有 zlib 与 rtime）。overlayfs 在没有
  xattr 支持的上层文件系统上照常工作，这与普通的 OpenWrt JFFS2 overlay 一样，只是目录没法标成"不透明"。
- **用旧版本写过的 Plugin 要擦一次**（里面有 xattr 节点，新内核也不认识，会回退到内存 overlay）。

下面几条仍是**推断**，没有在设备上演练：

- 原厂写的块（清除标记在 OOB，数据从页 0 开始）：我们的内核不再读 OOB 里的清除标记，带数据的块照常扫描。
- 原厂留下的空块（只有 OOB 里的标记）：挂载时被当作"未格式化"，擦一次，之后写上数据区里的清除标记。
- 原厂自己擦块、写块时也是先单独往页 0 的 OOB 写清除标记再写数据（**读码**：原厂 JFFS2 有
  `jffs2_write_nand_cleanmarker`，上面日志里清除标记大小是 0），也就是第 2 节说的"同一页写两次"。
  **它为什么没坏，没有查清。** 读原厂内核（5.4.196，`kernel-2b5.elf` 反汇编）得到的事实：
  - 它的 SPI-NAND 层与主线 5.4 同一套流程：非 RAW 请求开片上 ECC（表项给了 ECC 参数时），写页是
    `write enable`、填 `0xff`、拷数据和 OOB、`PROGRAM EXECUTE (0x10)`；ECC 不可纠正返回 `-74`，
    JFFS2 读到就会像我们一样拒绝挂载。
  - 但它对这颗芯片（ID `ef ae 21`，表项 `W25N01KV`）的描述与主线不同：**OOB 大小 64**（主线 96），
    ECC 要求 4 位/512 字节，OOB 布局用 `w25m02gv_ooblayout`——假定校验位在每 16 字节的第 8 到 15 字节，
    可用字节是每段的第 2 到 7 字节，共 24 字节（主线：校验位在 64 到 95 的额外区域，可用字节每段 2 到 15，共 56 字节）。
  - 因此 8 字节的清除标记在原厂落在 OOB 的 2–7 和 18–19，在我们落在 2–9；每次写页发给芯片的 OOB 长度
    原厂 64 字节，我们 96 字节。
  这些差异可能与"为什么原厂不坏"有关，但没有验证。这也意味着第 2 节对原因的解释只是推断：
  它解释了我们的现象，也解释了改动之后为什么好了，但没有解释原厂。我们的内核读这种页时，数据仍然可用
  （JFFS2 容忍数据读的 ECC 错误），但不保证。
- 以前**用没有第 3 节那项改动的内核**写过 Plugin 的，里面会有 ECC 已经坏掉的页，要整个擦掉
  （原厂插件数据随之丢失）。

**还没验证的**：用不带 xattr 的新内核写过的 Plugin，原厂能不能挂载并使用；原厂使用过之后，回到 OpenWrt
overlay 是否完好。

## 6. 排查

- `/dev/mtdN`（字符设备）读到 `-EBADMSG` 时仍然返回数据，所以用 `dd` 扫它**查不出**这类坏页。
  用 `/dev/mtdblockN`（读出错返回 `EIO`），或者看 `/sys/class/mtd/mtdN/ecc_failures`。
- 已经损坏、需要重来的恢复办法：在 U-Boot 里擦整个 Plugin，会丢原厂插件数据：

  ```text
  nand erase 5800000 2800000
  reset
  ```

  只擦单个块（Plugin 内偏移加 `0x5800000`）只适合已经定位的坏块，例如 `nand erase 73e0000 20000`。

## 7. 日志里的 summary 警告（历史）

在带 summary 的版本里，挂载之后偶尔会有一行：

```text
jffs2: warning: jffs2_sum_write_data: Not enough space for summary, padsize = -999
```

**读码**：JFFS2 关闭一个块时，把当前没写满的一页用填充补满，补出来的空间占掉了为摘要节点预留的位置，
摘要放不下，就不给这个块写摘要，数据不受影响。现在已经不编译 summary，这行不会再出现。

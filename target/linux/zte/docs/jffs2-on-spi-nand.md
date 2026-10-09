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

**数据手册**（Winbond W25N01KV，Rev.A，2023-10-16，第 7.2.4 节）：

- ECC 开着时（上电默认），校验位在**编程时**由芯片生成，存放在每页额外的 32 字节区域（地址 `840h`–`85Fh`，由芯片控制）；
  这与主线的 OOB 布局（OOB 96 字节，校验位在 64 之后）一致。
- 每个 16 字节的 spare 段分成 UD2（前 4 字节，**不受 ECC 保护**）和 UD1（后 12 字节，**受保护**）；
  每个 512 字节扇区的校验位覆盖这个扇区加上与它配对的 UD1。
- 一页可以局部编程 4 次（NoP = 4），但手册写明：要把"一个扇区和与它配对的 UD1 **一次编程**"，
  才能正确地自动生成校验位。
- NAND 的位只能从 1 写成 0，同一扇区的校验位被生成两次，留下的是两次结果按位相与。

JFFS2 的清除标记（8 字节）写在第 0 页 spare 里，我们落在字节 2–9（其中 4–9 在受保护的 UD1），
之后第一个数据节点写进扇区 0：同一个扇区和它的 UD1 被分两次编程，校验位对不上，这一页之后读出来就是
不可纠正的 ECC 错误。这与实测一致（只被编程一次的空块读得正常，写过数据的块读不出来；改成每页只编程一次
之后同样的实验不再失败）。

**真机验证**（`docs/w25ntest/`里的小程序，W25N01KV，我们的内核，ECC 开启，`/dev/mtd4` 尾部的空块）：

- 数据和清除标记**一次**编程，或者清除标记只写在不受保护的 UD2 字节里再写数据：页完好。
- 清除标记写在受保护的 UD1（我们的位置 spare 2–9、原厂的位置 spare 2–7 和 18–19、扇区 1 的 UD1），再写数据，
  或者先写数据再写清除标记：校验位坏。不带 ECC 的原始读显示**格子里的数据始终是写入的数据，坏的只有校验位**。
- 机制：这些页里芯片存的校验位逐位等于两次编程各自校验位的**按位相与**（只有数据的页 AND 只有清除标记的页），
  不等于一次编程时的正确校验位。
- 63 个页、每页数据不同的统计（每种写法 21 页）：

  | 写法 | 不可纠正 | ECC 报成功（或"纠正了位"）但数据是错的 | 完好 |
  | --- | --- | --- | --- |
  | 旧的 JFFS2 写法 | 15 | 6 | 0 |
  | 原厂的写法 | 13 | 8 | 0 |
  | 一次编程（对照） | 0 | 0 | 21 |

- "数据是错的"是 ECC 的**误纠正**：合并后的校验位让解码器把正确的数据位翻转了（一次测试里 `EUCLEAN`、纠正 1 位，
  实际有 1 个字节和写入的不同）。内核把它当成功，上层看不到任何错误；JFFS2 只能靠每个节点自带的 CRC 发现，
  发现后丢弃该节点。没有一页是"校验位有错但被正确纠回"。

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
- 对照数据手册：原厂假定校验位在每个 16 字节段的第 8–15 字节，**与手册不符**（校验位在额外的 32 字节区域，
  主线是对的）。它的 8 字节清除标记落在字节 2–7 和 18–19，其中字节 4–7 在受保护的 UD1 里，按手册的规则
  它同样会把第 0 页扇区 0 的校验位弄坏。但 2026-09-13 的验收里，我们的内核（开着 ECC）以只读方式挂载原厂
  用过的 Plugin 和 usercfg 都成功，读每个块的 OOB 都没有出错，所以原厂实际并没有（至少没有普遍地）弄坏页。
  原因不明。
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

**共用 Plugin：推论，以及第一次共存演练**

- 推论（来自上面的统计）：原厂系统往 Plugin 写数据、回收块时，会用它自己的方式（清除标记写进 OOB，再写数据）
  重新使用块，这些块的第 0 页应当按上面的比例被弄坏：大约三分之二读不出来（我们的 JFFS2 对数据读的 ECC 错误是
  容忍的，数据仍可用），大约三分之一读出错误的数据（节点 CRC 不匹配，节点被丢弃）。
- **第一次演练**（`docs/coexist/`，终版，原厂 2B5 装在槽 1）：OpenWrt 先在 overlay 里放 20 个 64 KiB 的随机文件，
  原厂挂载 Plugin，写 40 个 256 KiB 的随机文件（10 MiB，至少 80 个块），然后从原厂网页重新刷 OpenWrt。回到 OpenWrt 后：
  20 个文件和原厂写的 40 个文件的校验和**全部一致**，`ecc_failures` 为 0。原厂在 Plugin 里自己建了 `apps`、
  `datainfo.json` 等目录和文件，说明它能挂载并使用这版 Plugin。
- 这与推论**不符**：原厂的真实写法和第 3 节模拟的 S3 有区别，区别在哪里不知道。这次演练只有 10 MiB，没有跑"删一半再写"
  的 churn 模式，原厂自己卸载再挂载的检查也没有做成（Plugin 被它的程序占用，`umount` 失败），所以不能断言原厂不会
  弄坏页。
- **答案：原厂的 JFFS2 在这颗芯片上根本不写清除标记。**
  - **读码**（原厂内核反汇编）：`jffs2_write_nand_cleanmarker` 编进去了，但**没有任何调用点**；擦完块之后只有"在数据区写
    清除标记节点"那一支，而原厂的 `cleanmarker_size` 是 0（它挂载时打印的 `normal 0x0`），所以什么都不写。
  - **实测**（`w25ntest --survey`，只读）：原厂用过之后，Plugin 里第 0 页块首是 JFFS2 节点的 163 个块，**没有一个**在 spare
    里有清除标记；也没有任何带 spare 清除标记的空块。另外 157 个块是我们的整页清除标记节点。
  - 所以原厂的每一页只编程一次，从不出现第 2 节的情形。第 3 节的 S3 是照标准 JFFS2 代码模拟的，不是原厂真实的行为。
  - 原厂为什么让判断函数为假（改了源码，还是别的原因），没有查到那一步。
  - 同一次扫描里有 6 页读出 `EUCLEAN`、各纠正 1 位，是普通的位翻转被 ECC 纠正，原厂和我们写的页 ECC 都正常。
  - 曾经的一个错误推断（已否定）：以为原厂写入时关着片上 ECC。扫描显示所有有数据的页都有校验位；关着 ECC 写的页
    开着 ECC 读会报不可纠正。

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

## 8. 启动时怎么认出共用卷里的 JFFS2

`mount_root` 要先判断 Plugin 是不是一个 JFFS2。共用卷里原厂也会写，前面的擦除块可能是空的。以前的代码只在前 1 MiB 里
找 JFFS2 节点；原厂用过之后这一段没有节点，卷被当成空盘（**实测**：`mount_root: no usable overlay filesystem found,
using tmpfs overlay`，JFFS2 到 61~67 秒才挂上，正常是约 25 秒）。现在扫整个卷、找到第一个节点就停（fstools 补丁
`204-shared-volume-scan-whole-volume.patch`）；完全空白的卷要读一遍全部，约 4 秒，只有第一次。

**读代码**：被当成空盘时，晚挂载的切换代码（`switch2jffs()`）会把内存 overlay 里的文件按同名拷进 `.owrt/`，可能把
设置换成首次启动的默认值。**这没有观察到**：那次启动之后配置完好。按代码这条分支应当先打印
`mount_root: no jffs2 marker found`，日志里没有这一行，但 JFFS2 确实在那时被挂上了，原因没有查清。

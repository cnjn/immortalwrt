<img src="https://avatars.githubusercontent.com/u/53193414?s=200&v=4" alt="ImmortalWrt logo" width="160" height="160" align="right">

# ImmortalWrt for ZTE SR1010

本仓库基于原项目 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 的
[v25.12.1](https://github.com/immortalwrt/immortalwrt/releases/tag/v25.12.1) 版本进行适配，
专用于 **ZTE SR1010（ZX279133 SoC）**。

生成的是**原厂升级包格式**的可刷写镜像：同一个 `.bin` 既能在原厂网页、LuCI
“备份/升级固件”页面或 `zte-fwslot` 里安装，路由器里的原厂系统和 ImmortalWrt
可以互相切换（固件分两个槽位，原厂 U-Boot 启动序列号最大的有效槽位）。

- 架构：ARM64
- SoC：ZTE ZX279133
- 设备：ZTE/ZXSLC SR1010
- 外部内核：Linux 6.18.38
- Web 管理：完整 LuCI，简体中文，默认 Argon 主题，另带可选的 AeroWRT（华硕风格）主题
- 网络：IPv6、硬件流量卸载、WireGuard、ZeroTier、dae 2.1.1
- 存储共享：USB 盘通过 ksmbd（SMB）共享，`wsdd2` 让 Windows 的“网络”里能看到路由器
- Mesh：内置 ZTE mesh 控制器（zte-mesh），中兴 mesh 子路由可以通过有线回程加入；默认关闭，在 LuCI 里填好 Wi-Fi 后启用
- 容器：LXC（含 LuCI 管理页，开机自启 `lxc-auto`）；容器根文件系统放 USB 盘
- 覆盖层放在 `Plugin` 分区的 `.owrt` 子目录，与原厂文件共存，恢复出厂不会删除原厂文件
- 另提供只在内存中运行的 FIT initramfs 镜像，用于调试

详细说明见 [target/linux/zte/README.md](target/linux/zte/README.md)。

> 本仓库是面向 SR1010 的设备适配分支，不是 ImmortalWrt 官方仓库。
> ImmortalWrt 的通用文档、软件包和其他设备支持请参考
> [ImmortalWrt 原项目](https://github.com/immortalwrt/immortalwrt)。

## 获取源码

构建需要本仓库和准备好的 ZX279133 Linux 内核仓库：

- ImmortalWrt 适配仓库：<https://github.com/cnjn/immortalwrt>
- Linux 内核仓库：<https://github.com/cnjn/linux-mainline-zte-zxslc-sr1010>

建议将两个仓库克隆到同一目录下：

```sh
mkdir sr1010-build
cd sr1010-build

git clone --branch build --recurse-submodules \
  https://github.com/cnjn/linux-mainline-zte-zxslc-sr1010.git

git clone --branch sr1010-zx279133 \
  https://github.com/cnjn/immortalwrt.git
```

目录结构应为：

```text
sr1010-build/
├── immortalwrt/
└── linux-mainline-zte-zxslc-sr1010/
    └── linux-6.18.38/
```

请务必为内核仓库使用 `--recurse-submodules`，否则不会取得实际的
`linux-6.18.38` 内核源码。

## 编译

先按照 [ImmortalWrt 官方构建文档](https://immortalwrt.org/docs/guide-developer/toolchain/install-buildsystem)
安装当前 Linux 发行版所需的编译依赖，然后执行：

```sh
cd sr1010-build/immortalwrt

./scripts/feeds update -a
./scripts/feeds install -a

SR1010_VENDOR_TEMPLATE=/绝对路径/原厂升级包.bin \
  ./scripts/configure-sr1010-flash.sh
make -j$(nproc)
```

原厂升级包（需要 `V1.0.0.2B7.8000`）不在本仓库中，构建时取其中的 U-Boot 和版本头。
dae 的 eBPF 程序由主机上的 `clang` 编译，需要先安装带 BPF 目标的 clang 和 LLVM。

配置脚本默认使用相邻目录中的内核：

```text
../linux-mainline-zte-zxslc-sr1010/linux-6.18.38
```

如果内核位于其他位置，可以显式指定绝对路径：

```sh
KERNEL_TREE=/absolute/path/to/linux-6.18.38 \
  SR1010_VENDOR_TEMPLATE=/绝对路径/原厂升级包.bin \
  ./scripts/configure-sr1010-flash.sh

make -j$(nproc)
```

内核目录必须是 `<目录>/linux-mainline-zte-zxslc-sr1010/linux-6.18.38`，
与 `<目录>/immortalwrt` 并列，脚本会检查。

编译产物位于 `bin/targets/zte/zx279133/`：

```text
immortalwrt-zte-zx279133-zte_zxslc-sr1010-flash-squashfs-sysupgrade.bin
immortalwrt-zte-zx279133-zte_zxslc-sr1010-flash-squashfs-sysupgrade-stock-uboot.bin
```

默认使用第一个：它带一处 U-Boot 补丁，解除原厂 U-Boot 对内核约 8 MiB 的限制。
第二个保持原厂 U-Boot 不变，只有内核 FIT 小于约 8 MB 时才能启动。
镜像放不进固件槽时，打包脚本会报错并停止。

## 刷机与切换

- LuCI“系统 → 备份/升级固件”或 `sysupgrade`：写入非运行槽位并重启进入。
- LuCI“系统 → 固件槽位”或 `zte-fwslot switch`：让另一个槽位成为下次启动，
  例如回到原厂系统。切换前会按原厂头部的 CRC 检查该槽位：U-Boot 选中了却起不来的槽，
  不会自动换成另一个（内核超过原厂 U-Boot 的限制时实测如此）。
- 从原厂系统回到 ImmortalWrt：在原厂网页里再刷一次镜像。**不要用原厂的 `fw_flashing -v switch`**：
  它就地改写另一个槽的版本头而不先擦除，NAND 只能把位从 1 变 0，写进去的是新旧字节按位与的结果，
  序号不会变大、CRC2 也会错，工具却报告成功。已在实机上验证，预测的字节与实测一致。
  详细说明和实测数据见 [target/linux/zte/docs/vendor-slots.md](target/linux/zte/docs/vendor-slots.md)。
- 复位键：短按重启，按住 5 秒恢复出厂设置。

## 默认设置

- LAN 地址：<http://192.168.5.1/>，用户名 `root`，默认密码为空
- 状态灯：WAN 能上网时为白色，否则为红色；插口旁的五个灯跟随各自端口的连接状态

## 网络性能

设备上实测（括号里标明的来自内核仓库的记录）：

- 板子接收（多条 TCP 流）：2.5G 的 LAN 口约 2.2G，已是 TCP 在 2.5G 上上限的 94%，两个接收队列都在工作（WAN 口记录为 2.35G）。
- 硬件流量卸载接管的路由/NAT 流量不经过 CPU（内核仓库记录约 2.3G）。
- 路由器自己发出的 TCP：单流约 1.4G，四流约 1.9G，两个核都满。驱动没有 SG 和 TSO，这部分被 CPU 拷贝和分段；
  不能硬件卸载的流量（dae、代理）走这条路径。
- LAN 口和交换芯片的 CPU 口不通告暂停，与 WAN 口一致。协商了暂停时上传只有约 0.95G，关掉后 2.22G；`ethtool -A` 不能再打开。

## 内存启动（initramfs）

调试时可以改用只在内存中运行的镜像，它不会改动闪存：

```sh
./scripts/configure-sr1010-initramfs.sh
make -j$(nproc)
```

产物是 `bin/targets/zte/zx279133/immortalwrt-zte-zx279133-zte_zxslc-sr1010-initramfs.itb`。

不要将 ITB 加载到 `0x82000000`，该地址可能与展开后的内核重叠。建议使用：

```text
tftpboot 0x88000000 immortalwrt-zte-zx279133-zte_zxslc-sr1010-initramfs.itb
bootm 0x88000000
```

内核和设备树的 load/entry 地址为 `0x80200000`。

内存启动后的信息：

- 串口：`115200n8`
- LAN：`lan1`–`lan4`
- LAN 地址：<http://192.168.1.1/>（initramfs 镜像）
- WAN：`eth0`

## 注意事项

initramfs 镜像仅在 RAM 中运行，重启后修改会丢失，不要当作可刷写的镜像使用。
可刷写镜像里，经实机验证过的有：补丁后的 U-Boot 启动、网口、LuCI、从原厂网页安装、
用 `zte-fwslot switch` 命令行切换到原厂系统；
尚未在实机上试过的有：LuCI 的“固件槽位”页面、复位键、指示灯的新行为（状态灯跟随 WAN、插口灯）、硬件流量卸载。

## License

本项目沿用 ImmortalWrt 的 [GPL-2.0-only](https://spdx.org/licenses/GPL-2.0-only.html)
许可证。原始项目及其贡献者的版权归各自所有。

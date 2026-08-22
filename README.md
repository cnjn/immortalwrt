<img src="https://avatars.githubusercontent.com/u/53193414?s=200&v=4" alt="ImmortalWrt logo" width="160" height="160" align="right">

# ImmortalWrt for ZTE SR1010

本仓库基于原项目 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 的
[v25.12.1](https://github.com/immortalwrt/immortalwrt/releases/tag/v25.12.1) 版本进行适配，
专用于 **ZTE SR1010（ZX279133 SoC）**。

当前生成的是供 U-Boot 内存启动的 **FIT initramfs 镜像**，用于设备适配、调试和验证：

- 架构：ARM64
- SoC：ZTE ZX279133
- 设备：ZTE/ZXSLC SR1010
- 外部内核：Linux 6.18.38
- Web 管理：最小 LuCI，默认使用 HTTP
- TLS 后端：mbedTLS
- SPI-NAND：保持只读
- 暂不生成可刷写的 factory 或 sysupgrade 镜像

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

./scripts/configure-sr1010-initramfs.sh
make -j$(nproc)
```

配置脚本默认使用相邻目录中的内核：

```text
../linux-mainline-zte-zxslc-sr1010/linux-6.18.38
```

如果内核位于其他位置，可以显式指定绝对路径：

```sh
KERNEL_TREE=/absolute/path/to/linux-6.18.38 \
  ./scripts/configure-sr1010-initramfs.sh

make -j$(nproc)
```

编译产物位于：

```text
bin/targets/zte/zx279133/immortalwrt-zte-zx279133-zte_zxslc-sr1010-initramfs.itb
```

## U-Boot 内存启动

不要将 ITB 加载到 `0x82000000`，该地址可能与展开后的内核重叠。建议使用：

```text
tftpboot 0x88000000 immortalwrt-zte-zx279133-zte_zxslc-sr1010-initramfs.itb
bootm 0x88000000
```

内核和设备树的 load/entry 地址为 `0x80200000`。

启动后默认信息：

- 串口：`115200n8`
- LAN：`lan1`–`lan4`
- LAN 地址：<http://192.168.1.1/>
- LuCI 用户名：`root`
- 默认密码：空
- WAN：`eth0`

## 注意事项

该镜像仅在 RAM 中运行，重启后修改会丢失。目前 SPI-NAND 保持只读，
请勿将此 ITB 当作可直接刷写的底包、factory 镜像或 sysupgrade 镜像使用。

## License

本项目沿用 ImmortalWrt 的 [GPL-2.0-only](https://spdx.org/licenses/GPL-2.0-only.html)
许可证。原始项目及其贡献者的版权归各自所有。

# SPDX-License-Identifier: GPL-2.0-only
# ZX279133 clocks, PHYs, XPCS and DSA core are provided by the ZTE target.
PKG_CONFIG_DEPENDS += CONFIG_ZTE_NPU_EXPERIMENTAL_VID_KEY

define KernelPackage/zte-npu
  SUBMENU:=Network Devices
  TITLE:=ZTE ZX279133 NPPT Ethernet data plane
  DEPENDS:=@TARGET_zte
  KCONFIG:=CONFIG_ZTE_ZX279133_ETH \
	CONFIG_ZTE_ZX279133_LAN_CONDUIT \
	CONFIG_ZTE_ZX279133_NATIVE_DEBUG=y
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/zte/npu.ko \
	$(LINUX_DIR)/drivers/net/ethernet/zte/zx279133-lan-conduit.ko
  MODPARAMS.npu:=$(if $(CONFIG_ZTE_NPU_EXPERIMENTAL_VID_KEY),experimental_vid_key=1)
  AUTOLOAD:=$(call AutoLoad,30,npu zx279133-lan-conduit,1)
endef

define KernelPackage/zte-npu/description
 Base NPPT MAC, DMA, PPU and hardware services. Normal software forwarding
 does not require the optional zte-fnoffload package. The existing ZTE target
 embeds the PPU microcode with CONFIG_EXTRA_FIRMWARE.
endef

define KernelPackage/zte-npu/config
  config ZTE_NPU_EXPERIMENTAL_VID_KEY
    bool "Experimental LAN IPv4 VLAN hardware flow keys"
    depends on PACKAGE_kmod-zte-npu && PACKAGE_kmod-zte-fnoffload
    default n
    help
      Cold-load NPU VID key layout and admit experimental VLAN pop/push rules.
      Requires the calibrated SR1010 firmware. Not verified for WAN tagged
      ingress, IPv6 VLAN or PPPoE combined with VLAN. Disable for normal builds.
endef

$(eval $(call KernelPackage,zte-npu))

define KernelPackage/zte-fnoffload
  SUBMENU:=Network Devices
  TITLE:=ZTE ZX279133 optional flowtable hardware offload
  DEPENDS:=@TARGET_zte +kmod-zte-npu +kmod-nf-flow
  KCONFIG:=CONFIG_ZTE_ZX279133_FNOFFLOAD
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/zte/fnoffload.ko
  MODPARAMS.fnoffload:=$(if $(CONFIG_ZTE_NPU_EXPERIMENTAL_VID_KEY),experimental_vlan=1)
  AUTOLOAD:=$(call AutoLoad,45,fnoffload)
endef

define KernelPackage/zte-fnoffload/description
 Translate Linux flow rules to NP hardware actions. Reload hardware nftables
 flowtables after installing/loading this module on an already running system.
endef

$(eval $(call KernelPackage,zte-fnoffload))

define KernelPackage/zte-rtl8372n
  SUBMENU:=Network Devices
  TITLE:=ZTE SR1010 RTL8372N DSA switch
  DEPENDS:=@TARGET_zte +kmod-zte-npu
  KCONFIG:=CONFIG_ZTE_ZX279133_RTL8372N
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/zte/zx279133-rtl8372n.ko
  AUTOLOAD:=$(call AutoLoad,35,zx279133-rtl8372n,1)
endef

$(eval $(call KernelPackage,zte-rtl8372n))

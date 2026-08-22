ARCH:=aarch64
SUBTARGET:=zx279133
BOARDNAME:=ZX279133 based boards
CPU_TYPE:=cortex-a53
KERNELNAME:=Image dtbs

# Keep the RAM image focused while providing a minimal LuCI administration UI.
DEFAULT_PACKAGES.tweak:=
DEFAULT_PACKAGES += \
	dnsmasq ethtool ip-full \
	luci-base luci-mod-admin-full luci-theme-bootstrap \
	uhttpd uhttpd-mod-ubus

define Target/Description
	Build initramfs FIT images for the ZTE ZX279133 SoC family.
endef

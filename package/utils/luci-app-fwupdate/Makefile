# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI page and overview notice for firmware updates
LUCI_DEPENDS:=+luci-base +fwupdate
LUCI_PKGARCH:=all

PKG_LICENSE:=GPL-2.0-only

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

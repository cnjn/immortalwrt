# SPDX-License-Identifier: GPL-2.0-only
include $(TOPDIR)/rules.mk

PKG_NAME:=npu-debug
PKG_RELEASE:=11
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/npu-debug
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=ZX279133 native NP hardware experiment tool
  DEPENDS:=@TARGET_zte +kmod-zte-npu +kmod-zte-fnoffload
endef

define Package/npu-debug/description
 On-demand native PLCR, scheduler and VLAN read/write experiments with
 per-open readback. No daemon, timer, register poking or automatic policy.
endef

define Build/Compile
endef

define Package/npu-debug/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/npu-debug $(1)/usr/sbin/npu-debug
endef

$(eval $(call BuildPackage,npu-debug))

# SPDX-License-Identifier: GPL-2.0-only
include $(TOPDIR)/rules.mk

PKG_NAME:=fwupdate
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/fwupdate
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Firmware updates from GitHub releases
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-math +ucode-mod-uci +curl +ca-bundle
  PKGARCH:=all
endef

define Package/fwupdate/description
  Checks the GitHub releases of the firmware once a day and installs a newer
  image with sysupgrade. A release is recognised by the revision at the end of
  its image name, for example sr1010-owrt-r38035-d301503f3e.bin.
endef

define Package/fwupdate/conffiles
/etc/config/fwupdate
endef

define Build/Compile
endef

define Package/fwupdate/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) ./files/fwupdate.uc $(1)/usr/sbin/fwupdate
	$(INSTALL_BIN) ./files/fwupdate.init $(1)/etc/init.d/fwupdate
	$(INSTALL_CONF) ./files/fwupdate.config $(1)/etc/config/fwupdate
endef

$(eval $(call BuildPackage,fwupdate))

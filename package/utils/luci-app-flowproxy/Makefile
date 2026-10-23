include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-flowproxy
PKG_VERSION:=1.0.3
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Support for FlowProxy Traffic Diversion
LUCI_DEPENDS:=+luci-base +nftables +ip-full
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/flowproxy
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/rpcd restart
}
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/flowproxy stop
	/etc/init.d/flowproxy disable
fi
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	rm -rf /tmp/flowproxy
	rm -rf /usr/share/flowproxy
	rm -f /var/log/flowproxy.log*
	rm -f /var/run/flowproxy.*
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

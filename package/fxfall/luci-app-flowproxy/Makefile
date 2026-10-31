include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-flowproxy
PKG_VERSION:=1.0.3
PKG_RELEASE:=13

LUCI_TITLE:=LuCI Support for FlowProxy Traffic Diversion
LUCI_DEPENDS:=+luci-base +nftables +ip-full +curl +jsonfilter
# Contains native ARM64 DNS and SOCKS health-check helpers.
LUCI_PKGARCH:=aarch64_cortex-a53

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
	/etc/init.d/flowproxy-guard stop
	/etc/init.d/flowproxy-guard disable
	/etc/init.d/flowproxy stop
	/etc/init.d/flowproxy-dns stop
	/etc/init.d/flowproxy disable
fi
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ] && [ "$${1:-remove}" = remove ]; then
	rm -rf /tmp/flowproxy
	rm -f /var/log/flowproxy.log*
	rm -f /var/run/flowproxy.*
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

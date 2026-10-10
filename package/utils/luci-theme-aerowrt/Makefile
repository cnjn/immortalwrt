#
# luci-theme-aerowrt - AeroWRT theme for LuCI
#
# Copyright 2026 AeroWRT contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=AeroWRT - ASUSWRT-inspired theme for LuCI
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

PKG_NAME:=luci-theme-aerowrt
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_MAINTAINER:=AeroWRT contributors

include $(TOPDIR)/feeds/luci/luci.mk

# Windows checkouts do not carry a POSIX executable bit. Normalize the
# first-boot UCI default in the OpenWrt build directory before packaging.
define Build/Prepare/luci-theme-aerowrt
	[ ! -f $(PKG_BUILD_DIR)/root/etc/uci-defaults/30_luci-theme-aerowrt ] || chmod 0755 $(PKG_BUILD_DIR)/root/etc/uci-defaults/30_luci-theme-aerowrt
endef

# call BuildPackage - OpenWrt buildroot signature

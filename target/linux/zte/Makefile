# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

BOARD:=zte
BOARDNAME:=ZTE SoCs
SUBTARGETS:=zx279133
FEATURES:=dt gpio ramdisk cpiogz usb
KERNEL_PATCHVER:=6.18

ifeq ($(DUMP),)
  ifeq ($(strip $(CONFIG_EXTERNAL_KERNEL_TREE)),)
    $(error The ZTE target requires CONFIG_EXTERNAL_KERNEL_TREE pointing to the prepared ZX279133 kernel)
  endif
endif

# The first SR1010 image is intentionally a small RAM-boot environment.
DEVICE_TYPE:=basic

include $(INCLUDE_DIR)/target.mk

define Target/Description
	Build RAM-boot images for supported ZTE SoCs.
endef

$(eval $(call BuildTarget))

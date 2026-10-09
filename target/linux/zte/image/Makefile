# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/image.mk

KERNEL_LOADADDR := 0x80200000
KERNEL_ENTRY := 0x80200000

# Path to a vendor upgrade package (.bin) that supplies the SR1010 U-Boot and
# version header template. It is not redistributed in this tree; set it with
# CONFIG_SR1010_VENDOR_TEMPLATE (see scripts/configure-sr1010-flash.sh).
SR1010_TEMPLATE := $(call qstrip,$(CONFIG_SR1010_VENDOR_TEMPLATE))

# Build a package in the vendor upgrade format from the kernel FIT and the
# squashfs root filesystem. No fwtool metadata is appended: the vendor
# flasher requires the file to end exactly where the version header says.
define Build/sr1010-firmware
	[ -f "$(SR1010_TEMPLATE)" ] || { \
		echo "CONFIG_SR1010_VENDOR_TEMPLATE must name a vendor upgrade package" >&2; \
		exit 1; }
	$(STAGING_DIR_HOST)/bin/python3 \
		$(TOPDIR)/target/linux/zte/mkfw/sr1010-mkfw.py \
		"$(SR1010_TEMPLATE)" "$(IMAGE_KERNEL)" "$(IMAGE_ROOTFS)" "$@" \
		--openssl "$(STAGING_DIR_HOST)/bin/openssl" \
		-v "$(VERSION_DIST) $(VERSION_NUMBER)" \
		-p "ZXSLC SR1010" $(1)
endef

define Device/Default
  PROFILES := Default
  KERNEL_NAME := Image
  # The vendor bootloader copies the whole kernel region into an 8 MiB heap
  # before it decrypts it, so the FIT has to stay small: lzma, not gzip.
  KERNEL = kernel-bin | lzma | \
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS = kernel-bin | gzip | \
	fit gzip $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_SUFFIX := .itb
  KERNEL_INITRAMFS_SUFFIX := .itb
  DEVICE_DTS_DIR := $(DTS_DIR)/zte
  IMAGES :=
endef

define Device/zte_zxslc-sr1010
  DEVICE_VENDOR := ZTE
  DEVICE_MODEL := ZXSLC SR1010
  DEVICE_DTS := zx279133-sr1010
  SUPPORTED_DEVICES := zte,zx279133-sr1010
  DEVICE_PACKAGES := zte-fwslot
endef
TARGET_DEVICES += zte_zxslc-sr1010

# Flashable variant: a vendor-format package that installs from the vendor web
# interface or from OpenWrt sysupgrade. Needs CONFIG_SR1010_VENDOR_TEMPLATE.
define Device/zte_zxslc-sr1010-flash
  $(Device/zte_zxslc-sr1010)
  DEVICE_VARIANT := Flash
  DEVICE_DTS := zx279133-sr1010-openwrt
  DEVICE_DTS_DIR := $(TOPDIR)/target/linux/zte/dts
  # sysupgrade.bin carries the patched U-Boot (checked on the board): the vendor
  # one cannot load a kernel FIT above about 8 MB. sysupgrade-stock-uboot.bin
  # keeps the vendor U-Boot byte for byte and only works while the FIT is small.
  IMAGES := sysupgrade.bin sysupgrade-stock-uboot.bin
  IMAGE/sysupgrade.bin := sr1010-firmware --patch-uboot
  IMAGE/sysupgrade-stock-uboot.bin := sr1010-firmware
endef
TARGET_DEVICES += zte_zxslc-sr1010-flash

$(eval $(call BuildImage))

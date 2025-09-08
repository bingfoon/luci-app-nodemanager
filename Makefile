include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-nodemanager
PKG_VERSION:=1.0.1
PKG_RELEASE:=r5

PKG_LICENSE:=MIT
PKG_MAINTAINER:=BingFoon Lee
PKG_BUILD_DEPENDS:=po2lmo/host   # <== 关键：确保编译 po2lmo

LUCI_TITLE:=Node Manager
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-compat

PO:=po

define Package/luci-app-nodemanager/conffiles
/etc/config/nodemanager
endef

include $(TOPDIR)/feeds/luci/luci.mk   # <== 关键：用 luci.mk 自动处理 i18n

# call BuildPackage - OpenWrt build system will create i18n subpackages automatically
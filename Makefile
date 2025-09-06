include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-nodemanager
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

LUCI_TITLE:=LuCI app for managing /etc/nikki/profiles/config.yaml
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base +luci-compat

include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,$(PKG_NAME)))

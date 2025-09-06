# luci-app-nodemanager/Makefile
include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI app for managing /etc/nikki/profiles/config.yaml
LUCI_PKGARCH:=all
PKG_NAME:=luci-app-nodemanager
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_DEPENDS:=+luci-compat +luci-base

include $(TOPDIR)/feeds/luci/luci.mk

PKG_MAINTAINER:=BingFoon Lee
PKG_LICENSE:=MIT

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_CONF) ./root/usr/share/rpcd/acl.d/luci-app-nodemanager.json $(1)/usr/share/rpcd/acl.d/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

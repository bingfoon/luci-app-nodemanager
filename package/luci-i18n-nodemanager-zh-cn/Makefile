include $(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-nodemanager-zh-cn
PKG_RELEASE:=6
LUCI_PKG_NAME:=nodemanager

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Chinese (zh-cn) translation for luci-app-$(LUCI_PKG_NAME)
  DEPENDS:=+luci-app-$(LUCI_PKG_NAME)
  PKGARCH:=all
endef

define Build/Compile
	@:
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/luci/i18n
	# 选 po 目录
	if [ -d "$(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh_Hans" ]; then PDIR="$(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh_Hans"; \
	elif [ -d "$(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh-cn" ]; then PDIR="$(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh-cn"; \
	else echo "No po dir found under luci-app-$(LUCI_PKG_NAME)"; exit 1; fi; \
	# 取一个 .po 并用它的基名当域名
	POFILE=$$(ls $$PDIR/*.po | head -n1); \
	[ -n "$$POFILE" ] || { echo "No .po file in $$PDIR"; exit 1; }; \
	DOMAIN=$$(basename "$$POFILE" .po); \
	# 定位 po2lmo
	PO2LMO="$(STAGING_DIR_HOSTPKG)/bin/po2lmo"; \
	if [ ! -x "$$PO2LMO" ]; then \
		$(MAKE) -C "$(TOPDIR)/feeds/luci/modules/luci-base/src" po2lmo; \
		PO2LMO="$(TOPDIR)/feeds/luci/modules/luci-base/src/po2lmo"; \
	fi; \
	[ -x "$$PO2LMO" ] || { echo "po2lmo not available"; exit 1; }; \
	"$$PO2LMO" "$$POFILE" "$(1)/usr/share/luci/i18n/$$DOMAIN.zh-cn.lmo"
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

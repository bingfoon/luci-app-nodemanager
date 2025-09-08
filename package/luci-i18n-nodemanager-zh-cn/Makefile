include $(TOPDIR)/rules.mk

APP_PKG:=luci-app-nodemanager
APP_DOMAIN:=nodemanager

PKG_NAME:=luci-i18n-$(APP_DOMAIN)-zh-cn
PKG_RELEASE:=6

# 确保 po2lmo 可用
PKG_BUILD_DEPENDS:=luci-base/host

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI translation Chinese (zh-cn) for $(APP_PKG)
  PKGARCH:=all
  DEPENDS:=+$(APP_PKG)
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/luci/i18n
	@set -e; \
	if [ -d "$(TOPDIR)/package/$(APP_PKG)/po/zh_Hans" ]; then \
		PDIR="$(TOPDIR)/package/$(APP_PKG)/po/zh_Hans"; \
	elif [ -d "$(TOPDIR)/package/$(APP_PKG)/po/zh-cn" ]; then \
		PDIR="$(TOPDIR)/package/$(APP_PKG)/po/zh-cn"; \
	else \
		echo "ERROR: no po dir: po/zh_Hans or po/zh-cn" >&2; exit 1; \
	fi; \
	POFILE=$$(find "$$PDIR" -maxdepth 1 -type f -name '*.po' | head -n1); \
	if [ -z "$$POFILE" ]; then echo "ERROR: no .po file found in $$PDIR" >&2; exit 1; fi; \
	PO2LMO_BIN="$(STAGING_DIR_HOSTPKG)/bin/po2lmo"; \
	if [ ! -x "$$PO2LMO_BIN" ]; then \
		$(MAKE) -C $(TOPDIR)/feeds/luci/modules/luci-base/src po2lmo || exit 1; \
		PO2LMO_BIN="$(TOPDIR)/feeds/luci/modules/luci-base/src/po2lmo"; \
	fi; \
	"$$PO2LMO_BIN" "$$POFILE" "$(1)/usr/share/luci/i18n/$(APP_DOMAIN).zh-cn.lmo"
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
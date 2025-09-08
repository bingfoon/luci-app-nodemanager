include $(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-nodemanager-zh-cn
PKG_RELEASE:=1

# 确保 host 侧 po2lmo 先被编好
PKG_BUILD_DEPENDS:=luci-base/host

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI translation Chinese (zh-cn) for luci-app-nodemanager
  PKGARCH:=all
  DEPENDS:=+luci-app-nodemanager
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/luci/i18n
	@set -e; \
	# 1) 找 po 目录（兼容 zh_Hans / zh-cn）
	for d in "$(TOPDIR)/package/luci-app-nodemanager/po/zh_Hans" "$(TOPDIR)/package/luci-app-nodemanager/po/zh-cn"; do \
		if [ -d "$$d" ]; then PDIR="$$d"; break; fi; \
	done; \
	[ -n "$$PDIR" ] || { echo "ERROR: no po dir: po/zh_Hans or po/zh-cn" >&2; exit 1; }; \
	# 2) 取第一个 .po 文件并以其基名当域名
	POFILE=$$(find "$$PDIR" -maxdepth 1 -type f -name '*.po' | head -n1); \
	[ -n "$$POFILE" ] || { echo "ERROR: no .po file found in $$PDIR" >&2; exit 1; }; \
	DOMAIN=$$(basename "$$POFILE" .po); \
	# 3) 定位 po2lmo（优先 hostpkg，其次 luci 源码）
	PO2LMO="$(STAGING_DIR_HOSTPKG)/bin/po2lmo"; \
	[ -x "$$PO2LMO" ] || PO2LMO="$(TOPDIR)/feeds/luci/modules/luci-base/src/po2lmo"; \
	[ -x "$$PO2LMO" ] || { echo "ERROR: po2lmo not found"; exit 1; }; \
	# 4) 生成 .lmo
	"$$PO2LMO" "$$POFILE" "$(1)/usr/share/luci/i18n/$$DOMAIN.zh-cn.lmo"
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

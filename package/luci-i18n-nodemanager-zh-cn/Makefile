include $(TOPDIR)/rules.mk

APP_PKG:=luci-app-nodemanager
# 如果你的翻译域不是 nodemanager，请改成你的域名（如 luci-app-nodemanager）
APP_DOMAIN:=nodemanager

PKG_NAME:=luci-i18n-$(APP_DOMAIN)-zh-cn
PKG_RELEASE:=6

# 确保 host 工具 po2lmo 已安装
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
	# 1) 找中文 .po 目录（兼容 zh_Hans 与 zh-cn）
	for d in "$(TOPDIR)/package/$(APP_PKG)/po/zh_Hans" "$(TOPDIR)/package/$(APP_PKG)/po/zh-cn"; do \
		if [ -d "$$d" ]; then PDIR="$$d"; break; fi; \
	done; \
	[ -n "$$PDIR" ] || { echo "ERROR: no po dir: po/zh_Hans or po/zh-cn" >&2; exit 1; }; \
	# 2) 取第一个 .po 文件
	POFILE=$$(find "$$PDIR" -maxdepth 1 -type f -name '*.po' | head -n1); \
	[ -n "$$POFILE" ] || { echo "ERROR: no .po file found in $$PDIR" >&2; exit 1; }; \
	# 3) 定位 po2lmo（优先 hostpkg，其次 luci 源码目录）
	PO2LMO="$(STAGING_DIR_HOSTPKG)/bin/po2lmo"; \
	[ -x "$$PO2LMO" ] || PO2LMO="$(TOPDIR)/feeds/luci/modules/luci-base/src/po2lmo"; \
	[ -x "$$PO2LMO" ] || { echo "ERROR: po2lmo not found"; exit 1; }; \
	# 4) 生成 .lmo
	"$$PO2LMO" "$$POFILE" "$(1)/usr/share/luci/i18n/$(APP_DOMAIN).zh-cn.lmo"
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

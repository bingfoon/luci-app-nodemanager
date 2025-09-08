# 新建（或覆盖）i18n 包的 Makefile
mkdir -p package/luci-i18n-nodemanager-zh-cn
cat > package/luci-i18n-nodemanager-zh-cn/Makefile <<'EOF'
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-nodemanager-zh-cn
PKG_RELEASE:=6

# 先确保 host 侧 po2lmo 可用
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
\t$(INSTALL_DIR) $(1)/usr/share/luci/i18n
\tset -e; \
\tfor d in "$(TOPDIR)/package/luci-app-nodemanager/po/zh_Hans" "$(TOPDIR)/package/luci-app-nodemanager/po/zh-cn"; do \
\t\tif [ -d "$$d" ]; then PDIR="$$d"; break; fi; \
\tdone; \
\t[ -n "$$PDIR" ] || { echo "ERROR: no po dir: po/zh_Hans or po/zh-cn" >&2; exit 1; }; \
\tPOFILE=$$(find "$$PDIR" -maxdepth 1 -type f -name '*.po' | head -n1); \
\t[ -n "$$POFILE" ] || { echo "ERROR: no .po file found in $$PDIR" >&2; exit 1; }; \
\tDOMAIN=$$(basename "$$POFILE" .po); \
\tPO2LMO="$(STAGING_DIR_HOSTPKG)/bin/po2lmo"; \
\t[ -x "$$PO2LMO" ] || PO2LMO="$(TOPDIR)/feeds/luci/modules/luci-base/src/po2lmo"; \
\t[ -x "$$PO2LMO" ] || { echo "ERROR: po2lmo not found"; exit 1; }; \
\t"$$PO2LMO" "$$POFILE" "$(1)/usr/share/luci/i18n/$$DOMAIN.zh-cn.lmo"
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
EOF

# 把行首的字面量 \t 替换成真实 Tab（仅 install 块）
sed -i $'/^define Package\\/.*\\/install/,/^endef/ s/^\\t/\t/' package/luci-i18n-nodemanager-zh-cn/Makefile

# 可选：强制 Unix 换行，避免 CRLF 导致奇怪报错
dos2unix package/luci-i18n-nodemanager-zh-cn/Makefile 2>/dev/null || true

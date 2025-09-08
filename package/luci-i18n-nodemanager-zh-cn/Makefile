include $(TOPDIR)/rules.mk

LUCI_PKG_NAME:=nodemanager
PKG_NAME:=luci-i18n-$(LUCI_PKG_NAME)-zh-cn
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

# 纯数据包：给它一个构建目录，避免默认规则报错
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

define Package/$(PKG_NAME)
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=Chinese (zh-cn) translation for luci-app-$(LUCI_PKG_NAME)
	DEPENDS:=+luci-app-$(LUCI_PKG_NAME)
	PKGARCH:=all
endef

# 优先 nodemanager.po；没有就取第一个 *.po
POFILE := \
  $(firstword \
    $(wildcard $(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh_Hans/$(LUCI_PKG_NAME).po) \
    $(wildcard $(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh-cn/$(LUCI_PKG_NAME).po) \
    $(wildcard $(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh_Hans/*.po) \
    $(wildcard $(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh-cn/*.po) \
  )
$(if $(POFILE),,$(error No .po found under package/luci-app-$(LUCI_PKG_NAME)/po/{zh_Hans,zh-cn}))

# —— 关键：把 Build 阶段设为 no-op —— 
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef
define Build/Configure
endef
define Build/Compile
	true
endef

# 安装阶段用 host 的 po2lmo 生成 .lmo
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/luci/i18n
	$(STAGING_DIR_HOSTPKG)/bin/po2lmo "$(POFILE)" \
		"$(1)/usr/share/luci/i18n/$(LUCI_PKG_NAME).zh-cn.lmo"
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

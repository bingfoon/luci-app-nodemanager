# SPDX-License-Identifier: MIT
# This is a minimal, modern LuCI app Makefile that auto-builds i18n packages.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-nodemanager
PKG_VERSION:=2.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT

# ===== LuCI meta =====
LUCI_TITLE:=Node Manager
# 根据你的实际运行依赖按需补充。最小只要 luci-base 即可。
LUCI_DEPENDS:=+luci-base
# 纯前端/脚本类应用通常可设为 all
LUCI_PKGARCH:=all

# 开启 i18n：指向翻译目录（见下方目录结构说明）
PO:=po

include $(TOPDIR)/feeds/luci/luci.mk

# 下面这行由 luci.mk 内部完成，不需要你再写：
# $(eval $(call BuildPackage,$(PKG_NAME)))

#!/bin/bash
# ============================================================
# luci-app-nodemanager — Docker 本地构建脚本
# 在 macOS/Linux 上无需安装任何编译工具链，一键生成 IPK
# ============================================================
set -euo pipefail

# ── 配置 ──
SDK_URL="https://downloads.openwrt.org/releases/24.10.2/targets/x86/64/openwrt-sdk-24.10.2-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
IMAGE_NAME="nodemanager-builder"
CONTAINER_NAME="nm-build-$$"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/dist"

echo "🔨 luci-app-nodemanager 本地 Docker 构建"
echo "   项目目录: $PROJECT_DIR"
echo "   输出目录: $OUTPUT_DIR"
echo ""

# ── 检查 Docker ──
if ! command -v docker &>/dev/null; then
    echo "❌ 未找到 docker，请先安装 Docker Desktop"
    exit 1
fi

# ── 构建 Docker 镜像（带缓存，首次约 2-3 分钟）──
echo "📦 构建 Docker 镜像（SDK 下载会被 Docker 缓存）..."
docker build -t "$IMAGE_NAME" -f - "$PROJECT_DIR" <<'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=dumb
ENV SDK_DIR=/opt/sdk
ENV FORCE_UNSAFE_CONFIGURE=1

# 安装 SDK 所需的全部编译依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gawk gettext unzip zstd rsync curl wget ca-certificates \
    python3 python3-distutils file libncurses-dev git perl \
    libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# 下载并解压 OpenWrt SDK（此步被 Docker layer 缓存）
ARG SDK_URL=https://downloads.openwrt.org/releases/24.10.2/targets/x86/64/openwrt-sdk-24.10.2-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst
RUN mkdir -p /tmp/sdk-dl && cd /tmp/sdk-dl && \
    curl -L --retry 3 -o sdk.tar.zst "$SDK_URL" && \
    tar --zstd -xf sdk.tar.zst && \
    mv openwrt-sdk-* "$SDK_DIR" && \
    rm -rf /tmp/sdk-dl

# 修改 feeds.conf：注释掉不需要的 feed，确保 luci feed 存在
RUN cd "$SDK_DIR" && \
    sed -i '/^src-git.\+telephony/s/^/#/' feeds.conf.default && \
    sed -i '/^src-git.\+routing/s/^/#/' feeds.conf.default && \
    (grep -qE '^src-git[[:space:]]+luci[[:space:]]' feeds.conf.default || \
     echo 'src-git luci https://github.com/openwrt/luci.git;openwrt-24.10' >> feeds.conf.default) && \
    cat feeds.conf.default

# 更新 luci feed 并安装 luci-base
RUN cd "$SDK_DIR" && \
    ./scripts/feeds update luci && \
    ./scripts/feeds install luci-base

# defconfig
RUN cd "$SDK_DIR" && make defconfig FORCE=1 || true

# 编译 po2lmo 工具
RUN make -C "$SDK_DIR" V=s FORCE=1 package/feeds/luci/luci-base/host/compile

WORKDIR /build
DOCKERFILE

echo ""
echo "🚀 开始编译..."

# ── 运行编译容器 ──
mkdir -p "$OUTPUT_DIR"

docker run --rm \
    --name "$CONTAINER_NAME" \
    -v "$PROJECT_DIR:/src:ro" \
    -v "$OUTPUT_DIR:/dist" \
    "$IMAGE_NAME" \
    bash -c '
set -euo pipefail
SDK_DIR=/opt/sdk

echo "==> 导入源码到 SDK..."
rsync -a --delete --exclude ".git" --exclude ".github" --exclude "dist" \
    /src/ "$SDK_DIR/package/luci-app-nodemanager"/

echo "==> 编译 luci-app-nodemanager..."
make -C "$SDK_DIR" V=s FORCE=1 -j1 package/luci-app-nodemanager/compile

echo "==> 创建 zh-cn i18n 包..."
python3 - <<'"'"'PY'"'"'
import os, pathlib
sdk = os.environ["SDK_DIR"]
d = pathlib.Path(sdk) / "package" / "luci-i18n-nodemanager-zh-cn"
d.mkdir(parents=True, exist_ok=True)
content = "\n".join([
    "include $(TOPDIR)/rules.mk",
    "",
    "LUCI_PKG_NAME:=nodemanager",
    "PKG_NAME:=luci-i18n-$(LUCI_PKG_NAME)-zh-cn",
    "PKG_RELEASE:=1",
    "",
    "include $(INCLUDE_DIR)/package.mk",
    "",
    "PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)",
    "",
    "define Package/$(PKG_NAME)",
    "\tSECTION:=luci",
    "\tCATEGORY:=LuCI",
    "\tSUBMENU:=3. Applications",
    "\tTITLE:=Chinese (zh-cn) translation for luci-app-$(LUCI_PKG_NAME)",
    "\tDEPENDS:=+luci-app-$(LUCI_PKG_NAME)",
    "\tPKGARCH:=all",
    "endef",
    "",
    "PO := $(firstword \\\\",
    "  $(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh_Hans/$(LUCI_PKG_NAME).po \\\\",
    "  $(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh-cn/$(LUCI_PKG_NAME).po)",
    "PO_ANY := $(firstword \\\\",
    "  $(wildcard $(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh_Hans/*.po) \\\\",
    "  $(wildcard $(TOPDIR)/package/luci-app-$(LUCI_PKG_NAME)/po/zh-cn/*.po))",
    "POFILE := $(if $(PO),$(PO),$(PO_ANY))",
    "",
    "define Build/Prepare",
    "\tmkdir -p $(PKG_BUILD_DIR)",
    "endef",
    "",
    "define Build/Configure",
    "endef",
    "",
    "define Build/Compile",
    "\ttrue",
    "endef",
    "",
    "define Package/$(PKG_NAME)/install",
    "\t$(INSTALL_DIR) $(1)/usr/share/luci/i18n",
    "\t$(STAGING_DIR_HOSTPKG)/bin/po2lmo \"$(POFILE)\" \"$(1)/usr/share/luci/i18n/$(LUCI_PKG_NAME).zh-cn.lmo\"",
    "endef",
    "",
    "$(eval $(call BuildPackage,$(PKG_NAME)))",
    ""
])
(d / "Makefile").write_text(content)
print("Wrote", d / "Makefile")
PY

echo "==> 编译 zh-cn i18n..."
make -C "$SDK_DIR" V=s FORCE=1 -j"$(nproc)" package/luci-i18n-nodemanager-zh-cn/compile

echo "==> 收集 IPK..."
find "$SDK_DIR/bin" -type f \( -name "luci-app-nodemanager_*.ipk" -o -name "luci-i18n-nodemanager-zh-cn_*.ipk" \) \
    -exec cp -v {} /dist/ \;

echo ""
echo "✅ 构建完成！IPK 文件："
ls -lh /dist/*.ipk 2>/dev/null || echo "⚠️  未找到 IPK 文件"
'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📁 IPK 输出目录: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"/*.ipk 2>/dev/null || echo "⚠️  未找到 IPK 文件"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "安装到路由器:  scp dist/*.ipk root@<router>:/tmp/"
echo "             ssh root@<router> 'opkg install /tmp/luci-app-*.ipk /tmp/luci-i18n-*.ipk'"

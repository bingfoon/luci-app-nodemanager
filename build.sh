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

# ── 构建 Docker 镜像（带缓存，首次约 5-10 分钟）──
echo "📦 构建 Docker 镜像（SDK 下载会被 Docker 缓存）..."
docker build -t "$IMAGE_NAME" --build-arg "SDK_URL=$SDK_URL" -f - "$PROJECT_DIR" <<'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=dumb
ENV SDK_DIR=/opt/sdk
ENV FORCE_UNSAFE_CONFIGURE=1

# 安装 SDK 编译依赖（精简：去掉未使用的 wget/python3-distutils）
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gawk gettext unzip zstd rsync curl ca-certificates \
    python3 file libncurses-dev git perl libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# 下载并解压 OpenWrt SDK（此步被 Docker layer 缓存）
ARG SDK_URL
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
     echo 'src-git luci https://github.com/openwrt/luci.git;openwrt-24.10' >> feeds.conf.default)

# 更新 feed 索引并安装 luci-base（注意：|| true 只作用于 defconfig）
RUN cd "$SDK_DIR" && \
    ./scripts/feeds update -a && \
    ./scripts/feeds install luci-base && \
    (make defconfig FORCE=1 || true)

# 直接从 luci-base 源码编译 po2lmo（跳过完整的 make host/compile，快得多）
RUN cd "$SDK_DIR/feeds/luci/modules/luci-base/src" && \
    mkdir -p "$SDK_DIR/staging_dir/host/bin" && \
    cc -std=gnu17 -o contrib/lemon contrib/lemon.c && \
    make po2lmo CC=gcc CFLAGS="-O2" LDFLAGS="" && \
    cp po2lmo "$SDK_DIR/staging_dir/host/bin/po2lmo" && \
    echo "✅ po2lmo 编译完成"

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
PKG_NAME=luci-app-nodemanager
PKG_VERSION=2.0.0-1

echo "==> 导入源码到 SDK..."
rsync -a --delete --exclude ".git" --exclude ".github" --exclude "dist" --exclude "package" \
    /src/ "$SDK_DIR/package/$PKG_NAME"/

echo "==> 编译 $PKG_NAME..."
make -C "$SDK_DIR" V=s FORCE=1 -j$(nproc) package/$PKG_NAME/compile

echo "==> 生成 zh-cn i18n IPK..."
POFILE="$SDK_DIR/package/$PKG_NAME/po/zh-cn/nodemanager.po"
I18N_PKG="luci-i18n-nodemanager-zh-cn"
I18N_VER="2.0.0-1"
if [ -f "$POFILE" ]; then
    # 1. po2lmo 转换
    TMPDIR=$(mktemp -d)
    mkdir -p "$TMPDIR/data/usr/share/luci/i18n"
    "$SDK_DIR/staging_dir/host/bin/po2lmo" "$POFILE" \
        "$TMPDIR/data/usr/share/luci/i18n/nodemanager.zh-cn.lmo"

    # 2. 构造 IPK 结构（IPK = ar 归档: debian-binary + control.tar.gz + data.tar.gz）
    echo "2.0" > "$TMPDIR/debian-binary"

    mkdir -p "$TMPDIR/control"
    cat > "$TMPDIR/control/control" <<CTRL
Package: $I18N_PKG
Version: $I18N_VER
Depends: luci-app-nodemanager
Section: luci
Architecture: all
Installed-Size: $(du -sb "$TMPDIR/data" | cut -f1)
Description: Chinese (zh-cn) translation for luci-app-nodemanager
CTRL

    # 3. 打包
    (cd "$TMPDIR/data"    && tar czf "$TMPDIR/data.tar.gz" .)
    (cd "$TMPDIR/control" && tar czf "$TMPDIR/control.tar.gz" .)
    (cd "$TMPDIR" && ar cr "/dist/${I18N_PKG}_${I18N_VER}_all.ipk" \
        debian-binary control.tar.gz data.tar.gz)
    rm -rf "$TMPDIR"
    echo "✅ i18n IPK 创建完成"
fi

echo "==> 收集 IPK..."
find "$SDK_DIR/bin" -type f -name "${PKG_NAME}_*.ipk" \
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

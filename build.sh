#!/bin/bash
# ============================================================
# luci-app-nodemanager — 纯 Shell IPK 打包脚本
# 无需 Docker / SDK / 交叉编译，本机直接生成 IPK
# ============================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/dist"
PKG_NAME="luci-app-nodemanager"

# 从 git 自动生成版本号
VERSION=$(cd "$PROJECT_DIR" && git describe --tags --abbrev=0 2>/dev/null || echo "2.0.0")
RELEASE=$(cd "$PROJECT_DIR" && git rev-list HEAD --count 2>/dev/null || echo "1")
PKG_VERSION="${VERSION}-${RELEASE}"

echo "🔨 $PKG_NAME 打包"
echo "   版本: $PKG_VERSION"
echo "   项目: $PROJECT_DIR"
echo ""

# ── 准备临时目录 ──
WORK=$(mktemp -d)
trap "rm -rf '$WORK'" EXIT

DATA="$WORK/data"
CTRL="$WORK/control"
mkdir -p "$DATA" "$CTRL"

# ── 收集文件 ──
# htdocs/ → /www/（LuCI 惯例：htdocs 映射到 web root）
if [ -d "$PROJECT_DIR/htdocs" ]; then
    mkdir -p "$DATA/www"
    cp -a "$PROJECT_DIR/htdocs/." "$DATA/www/"
    echo "  ✓ htdocs → /www/"
fi

# root/ → /（原样安装）
if [ -d "$PROJECT_DIR/root" ]; then
    cp -a "$PROJECT_DIR/root/." "$DATA/"
    echo "  ✓ root → /"
fi

# files/ → /（原样安装）
if [ -d "$PROJECT_DIR/files" ]; then
    cp -a "$PROJECT_DIR/files/." "$DATA/"
    echo "  ✓ files → /"
fi

# 统计安装大小
if stat --version &>/dev/null 2>&1; then
    # GNU stat (Linux)
    INSTALLED_SIZE=$(du -sb "$DATA" | cut -f1)
else
    # BSD stat (macOS)
    INSTALLED_SIZE=$(find "$DATA" -type f -exec stat -f%z {} + | awk '{s+=$1}END{print s}')
fi

echo ""
echo "  📦 安装大小: ${INSTALLED_SIZE} bytes"
echo ""

# ── 生成 control 文件 ──
cat > "$CTRL/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Depends: luci-base
Section: luci
Architecture: all
Installed-Size: $INSTALLED_SIZE
Description: LuCI Node Manager - manage proxy nodes for nikki/Mihomo
EOF

# postinst: 安装后刷新 rpcd ACL 和 uhttpd
cat > "$CTRL/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    /etc/init.d/rpcd restart 2>/dev/null
    /etc/init.d/uhttpd restart 2>/dev/null
    rm -rf /tmp/luci-modulecache /tmp/luci-indexcache* 2>/dev/null
}
exit 0
EOF
chmod +x "$CTRL/postinst"

# prerm: 卸载前清理 LuCI 缓存（否则菜单残留）
cat > "$CTRL/prerm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    rm -rf /tmp/luci-modulecache /tmp/luci-indexcache* 2>/dev/null
}
exit 0
EOF
chmod +x "$CTRL/prerm"

# ── 打包 IPK（标准 opkg 格式：ar 归档 = debian-binary + control.tar.gz + data.tar.gz）──
echo "2.0" > "$WORK/debian-binary"
(cd "$DATA" && tar czf "$WORK/data.tar.gz" .)
(cd "$CTRL" && tar czf "$WORK/control.tar.gz" .)

mkdir -p "$OUTPUT_DIR"
IPK_FILE="$OUTPUT_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk"

# 清理旧的同名 IPK
rm -f "$OUTPUT_DIR/${PKG_NAME}_"*.ipk

(cd "$WORK" && ar cr "$IPK_FILE" debian-binary control.tar.gz data.tar.gz)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 打包完成！"
ls -lh "$IPK_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "安装到路由器:"
echo "  scp $IPK_FILE root@<router>:/tmp/"
echo "  ssh root@<router> 'opkg install /tmp/$(basename "$IPK_FILE")'"

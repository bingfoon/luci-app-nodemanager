#!/bin/bash
# ============================================================
# luci-app-nodemanager — 纯 Shell + Python IPK 打包脚本
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
mkdir -p "$DATA"

# ── 收集文件 ──
# htdocs/ → /www/
if [ -d "$PROJECT_DIR/htdocs" ]; then
    mkdir -p "$DATA/www"
    cp -a "$PROJECT_DIR/htdocs/." "$DATA/www/"
    echo "  ✓ htdocs → /www/"
fi

# root/ → /
if [ -d "$PROJECT_DIR/root" ]; then
    cp -a "$PROJECT_DIR/root/." "$DATA/"
    echo "  ✓ root → /"
fi

# files/ → /
if [ -d "$PROJECT_DIR/files" ]; then
    cp -a "$PROJECT_DIR/files/." "$DATA/"
    echo "  ✓ files → /"
fi

echo ""

# ── 用 Python 生成标准 IPK（精确控制 tar/ar 二进制格式）──
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/${PKG_NAME}_"*.ipk

python3 - "$DATA" "$OUTPUT_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk" "$PKG_NAME" "$PKG_VERSION" <<'PYTHON'
import sys, os, io, tarfile, struct, time, gzip

data_dir, output_path, pkg_name, pkg_version = sys.argv[1:5]

def make_tar_gz(base_dir=None, files_dict=None):
    """Create a .tar.gz in memory using GNU tar format."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz', format=tarfile.GNU_FORMAT) as tar:
        if base_dir:
            for root, dirs, files in os.walk(base_dir):
                # Add directory
                arcname = './' + os.path.relpath(root, base_dir)
                if arcname == './.':
                    arcname = './'
                else:
                    arcname += '/'
                info = tarfile.TarInfo(name=arcname)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.mtime = time.time()
                tar.addfile(info)
                # Add files
                for fname in sorted(files):
                    full = os.path.join(root, fname)
                    arcname = './' + os.path.relpath(full, base_dir)
                    tar.add(full, arcname=arcname)
        elif files_dict:
            for name, content in files_dict.items():
                info = tarfile.TarInfo(name='./' + name)
                data = content.encode('utf-8') if isinstance(content, str) else content
                info.size = len(data)
                info.mode = 0o755 if name.endswith(('.sh', 'postinst', 'prerm')) else 0o644
                info.mtime = time.time()
                tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()

def make_ar(output_path, members):
    """Create a GNU ar archive."""
    with open(output_path, 'wb') as f:
        f.write(b'!<arch>\n')
        for name, data in members:
            # AR header: name/16 mtime/12 uid/6 gid/6 mode/8 size/10 end/2
            name_bytes = name.encode('utf-8')
            header = b'%-16s%-12s%-6s%-6s%-8s%-10s\x60\n' % (
                name_bytes, b'0', b'0', b'0', b'100644', str(len(data)).encode()
            )
            f.write(header)
            f.write(data)
            if len(data) % 2:
                f.write(b'\n')

# Calculate installed size
total_size = sum(
    os.path.getsize(os.path.join(r, f))
    for r, _, files in os.walk(data_dir)
    for f in files
)

# Build control files
control = f"""Package: {pkg_name}
Version: {pkg_version}
Depends: luci-base
Section: luci
Architecture: all
Installed-Size: {total_size}
Description: LuCI Node Manager - manage proxy nodes for nikki/Mihomo
"""

postinst = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    /etc/init.d/rpcd restart 2>/dev/null
    /etc/init.d/uhttpd restart 2>/dev/null
    rm -rf /tmp/luci-modulecache /tmp/luci-indexcache* 2>/dev/null
}
exit 0
"""

prerm = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    rm -rf /tmp/luci-modulecache /tmp/luci-indexcache* 2>/dev/null
}
exit 0
"""

# Create tar.gz archives
control_tar_gz = make_tar_gz(files_dict={
    'control': control,
    'postinst': postinst,
    'prerm': prerm,
})
data_tar_gz = make_tar_gz(base_dir=data_dir)

# Assemble IPK (ar archive)
make_ar(output_path, [
    ('debian-binary', b'2.0\n'),
    ('control.tar.gz', control_tar_gz),
    ('data.tar.gz', data_tar_gz),
])

print(f"  📦 安装大小: {total_size} bytes")
print(f"  📦 IPK 大小: {os.path.getsize(output_path)} bytes")
PYTHON

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 打包完成！"
ls -lh "$OUTPUT_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "安装到路由器:"
echo "  scp $OUTPUT_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk root@<router>:/tmp/"
echo "  ssh root@<router> 'opkg install /tmp/${PKG_NAME}_${PKG_VERSION}_all.ipk'"

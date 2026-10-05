#!/usr/bin/env bash
#
# 一键打包工具: 编译 MyMusicCD, 制作 deb 安装包和 tar.gz 压缩包
# 用法: ./bld.sh [选项]
#
# 功能:
#   1. 编译 MyMusicCD (Flutter Linux Release)
#   2. 制作 deb 安装包 (安装到 /opt/MyMusicCD, 含桌面菜单项和启动命令)
#   3. 制作 tar.gz 绿色版压缩包 (解压即可运行)
#
# 选项:
#   -v, --version <版本>  指定版本号 (默认读取 pubspec.yaml 的 version)
#   -h, --help            显示本帮助
#
# 产物 (输出到 dist/ 目录):
#   mymusiccd_<版本>_<架构>.deb           deb 安装包
#   MyMusicCD-<版本>-linux-<架构>.tar.gz  绿色版压缩包

set -euo pipefail

# ---------------- 路径与默认参数 ----------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUI_DIR="$SCRIPT_DIR/MyMusicCD"
DIST_DIR="$SCRIPT_DIR/dist"
ICON_DIR="$GUI_DIR/assets/icons"           # Linux 图标 (平台无关资源)

PKG_NAME="mymusiccd"          # deb 包名
BIN_NAME="MyMusicCD"          # 可执行文件名
APP_ID="top.mydata.MyMusicCD"  # GTK 应用 ID (与 linux/CMakeLists.txt 一致)
INSTALL_DIR="/opt/MyMusicCD"  # deb 安装位置

VERSION=""

# ---------------- 帮助 ----------------
usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------- 解析参数 ----------------
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version) VERSION="${2:-}"; shift 2 ;;
        -h|--help)    usage ;;
        -*) echo "未知选项: $1" >&2; exit 1 ;;
        *)  echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

# ---------------- 检查依赖 ----------------
for cmd in flutter dpkg-deb dpkg tar; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "错误: 未找到所需命令: $cmd" >&2
        exit 1
    }
done

# ---------------- 读取版本号 ----------------
if [ -z "$VERSION" ]; then
    VERSION="$(awk '/^version:/ {print $2; exit}' "$GUI_DIR/pubspec.yaml")"
fi
if [ -z "$VERSION" ]; then
    echo "错误: 无法获取版本号 (pubspec.yaml 或 -v 选项)" >&2
    exit 1
fi

# ---------------- 计算架构 ----------------
case "$(uname -m)" in
    x86_64|amd64)  FLUTTER_ARCH="x64" ;;
    aarch64|arm64) FLUTTER_ARCH="arm64" ;;
    *)             FLUTTER_ARCH="$(uname -m)" ;;
esac
DEB_ARCH="$(dpkg --print-architecture)"

echo "========================================"
echo "我的音乐CD 打包"
echo "版本: $VERSION    架构: $FLUTTER_ARCH (deb: $DEB_ARCH)"
echo "========================================"

# ---------------- 1. 编译 ----------------
echo "[1/3] 编译 MyMusicCD (Release) ..."
( cd "$GUI_DIR" && flutter build linux --release )

# 定位编译产物 bundle
BUNDLE_DIR="$GUI_DIR/build/linux/$FLUTTER_ARCH/release/bundle"
if [ ! -d "$BUNDLE_DIR" ]; then
    BUNDLE_DIR="$(find "$GUI_DIR/build/linux" -maxdepth 3 -type d \
                  -path '*/release/bundle' -print -quit 2>/dev/null || true)"
fi
if [ -z "$BUNDLE_DIR" ] || [ ! -x "$BUNDLE_DIR/$BIN_NAME" ]; then
    echo "错误: 未找到编译产物: ${BUNDLE_DIR:-$GUI_DIR/build/linux/*/release/bundle}" >&2
    exit 1
fi

# 打包用临时目录 (退出时自动清理)
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------- 2. 制作 tar.gz ----------------
echo "[2/3] 制作 tar.gz 压缩包 ..."
TAR_NAME="MyMusicCD-${VERSION}-linux-${FLUTTER_ARCH}"
TAR_STAGE="$WORK_DIR/$TAR_NAME"
mkdir -p "$TAR_STAGE"
cp -a "$BUNDLE_DIR/." "$TAR_STAGE/"
cat > "$TAR_STAGE/README.md" <<EOF
# 我的音乐CD GUI $VERSION (linux-$FLUTTER_ARCH)

音乐 CD 制作工具 (Flutter 图形界面版)。

## 运行

    ./MyMusicCD

## 运行依赖

- GTK 3 (libgtk-3-0)
- ffmpeg / ffprobe (音乐格式转换)
- cdrecord (CD 刻录, wodim 包)
- genisoimage / mkisofs / xorriso (可选, 生成 ISO 镜像)
EOF
mkdir -p "$DIST_DIR"
tar -czf "$DIST_DIR/${TAR_NAME}.tar.gz" -C "$WORK_DIR" "$TAR_NAME"
echo "  -> $DIST_DIR/${TAR_NAME}.tar.gz"

# ---------------- 3. 制作 deb ----------------
echo "[3/3] 制作 deb 安装包 ..."
DEB_STAGE="$WORK_DIR/deb"
mkdir -p "$DEB_STAGE/DEBIAN" \
         "$DEB_STAGE$INSTALL_DIR" \
         "$DEB_STAGE/usr/share/applications" \
         "$DEB_STAGE/usr/bin"

# 包控制信息
MAINTAINER="$(git config user.name 2>/dev/null || echo 'unknown') <$(git config user.email 2>/dev/null || echo 'unknown')>"
cat > "$DEB_STAGE/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Section: sound
Priority: optional
Architecture: $DEB_ARCH
Depends: libgtk-3-0, libglib2.0-0, libc6, libstdc++6, ffmpeg, wodim
Recommends: genisoimage | xorriso
Maintainer: $MAINTAINER
Description: 音乐 CD 制作工具 (GUI)
 制作音乐 CD 工具:
 扫描、排序、评估容量、转换为 44.1kHz/16bit/立体声 WAV, 使用ffmpeg自动转换音频格式
 生成 CUE 文件, 用 cdrecord 刻录音频 CD 或打包成 ISO 镜像。
EOF

# 安装程序文件
cp -a "$BUNDLE_DIR/." "$DEB_STAGE$INSTALL_DIR/"

# 桌面菜单项 (文件名须与 GTK 应用 ID 一致, 供桌面环境关联)
cat > "$DEB_STAGE/usr/share/applications/${APP_ID}.desktop" <<EOF
[Desktop Entry]
Name=我的音乐CD
Comment=音乐 CD 制作工具
Exec=$INSTALL_DIR/$BIN_NAME
Icon=MyMusicCD
Terminal=false
Type=Application
Categories=AudioVideo;AudioVideoEditing;
StartupWMClass=$APP_ID
EOF

# 应用图标 (取自 assets/icons, 各尺寸, hicolor 主题标准)
for size in 16 32 48 64 128 256 512; do
    icon="$ICON_DIR/MyMusicCD_${size}.png"
    [ -f "$icon" ] || continue
    mkdir -p "$DEB_STAGE/usr/share/icons/hicolor/${size}x${size}/apps"
    cp "$icon" "$DEB_STAGE/usr/share/icons/hicolor/${size}x${size}/apps/MyMusicCD.png"
done

# 命令行启动入口 (相对路径软链, 解压测试时也能正确解析)
ln -sf "../../opt/MyMusicCD/$BIN_NAME" "$DEB_STAGE/usr/bin/$BIN_NAME"

# 打包 (文件属主强制设为 root:root)
DEB_OUT="$DIST_DIR/${PKG_NAME}_${VERSION}_${DEB_ARCH}.deb"
DEB_HELP="$(dpkg-deb --help 2>&1 || true)"
if [[ "$DEB_HELP" == *--root-owner-group* ]]; then
    dpkg-deb --build --root-owner-group "$DEB_STAGE" "$DEB_OUT"
elif command -v fakeroot >/dev/null 2>&1; then
    fakeroot dpkg-deb --build "$DEB_STAGE" "$DEB_OUT"
else
    echo "错误: dpkg-deb 不支持 --root-owner-group 且未安装 fakeroot" >&2
    exit 1
fi

echo "========================================"
echo "打包完成:"
ls -lh "$DEB_OUT" "$DIST_DIR/${TAR_NAME}.tar.gz" | sed 's/^/  /'
echo "========================================"

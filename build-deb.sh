#!/usr/bin/env bash
#
# build-deb.sh - Automated Debian package builder for Folder-Locker (v1.0)
#

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}       Folder-Locker: Debian Package Builder        ${NC}"
echo -e "${BLUE}====================================================${NC}"

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] 'dpkg-deb' is not installed on this system.${NC}"
    echo "Install it with: sudo apt install dpkg"
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

REQUIRED_FILES=(
    "folderlock-core.sh"
    "adapters/folderlock.nemo_action"
    "adapters/folderlock.desktop"
    "adapters/folderlock.py"
    "adapters/folderlock-monitor.desktop"
    "debian/control"
    "debian/postinst"
    "debian/postrm"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo -e "${RED}[ERROR] Required file not found: $file${NC}"
        exit 1
    fi
done

PKG_NAME="$(grep '^Package:' debian/control | awk '{print $2}')"
PKG_VERSION="$(dpkg-parsechangelog -S Version 2>/dev/null || grep '^Version:' debian/control | awk '{print $2}' || echo '1.0.0-1')"
PKG_ARCH="$(grep '^Architecture:' debian/control | awk '{print $2}')"
BUILD_DIR="build"
OUTPUT_DEB="${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"

echo -e "${YELLOW}>> Cleaning up previous builds...${NC}"
rm -rf "$BUILD_DIR"
rm -f "$OUTPUT_DEB"

echo -e "${YELLOW}>> Creating package directory structure...${NC}"
mkdir -p "$BUILD_DIR/DEBIAN"
mkdir -p "$BUILD_DIR/usr/bin"
mkdir -p "$BUILD_DIR/usr/share/nemo/actions"
mkdir -p "$BUILD_DIR/usr/share/kservices5/ServiceMenus"
mkdir -p "$BUILD_DIR/usr/share/kio/servicemenus"
mkdir -p "$BUILD_DIR/usr/share/nautilus-python/extensions"
mkdir -p "$BUILD_DIR/etc/xdg/autostart"
mkdir -p "$BUILD_DIR/usr/share/doc/$PKG_NAME"

echo -e "${YELLOW}>> Copying system files and adapters...${NC}"

# Core binary
cp folderlock-core.sh "$BUILD_DIR/usr/bin/folderlock"

# Context menu adapters
cp adapters/folderlock.nemo_action "$BUILD_DIR/usr/share/nemo/actions/folderlock.nemo_action"
cp adapters/folderlock.desktop "$BUILD_DIR/usr/share/kservices5/ServiceMenus/folderlock.desktop"
cp adapters/folderlock.desktop "$BUILD_DIR/usr/share/kio/servicemenus/folderlock.desktop"
cp adapters/folderlock.py "$BUILD_DIR/usr/share/nautilus-python/extensions/folderlock.py"

# Autostart for cascade deletion monitor
cp adapters/folderlock-monitor.desktop "$BUILD_DIR/etc/xdg/autostart/folderlock-monitor.desktop"

# Debian control and lifecycle scripts
if grep -q '^Version:' debian/control; then
    cp debian/control "$BUILD_DIR/DEBIAN/control"
else
    cat debian/control > "$BUILD_DIR/DEBIAN/control"
    echo "Version: $PKG_VERSION" >> "$BUILD_DIR/DEBIAN/control"
fi
cp debian/postinst "$BUILD_DIR/DEBIAN/postinst"
cp debian/postrm "$BUILD_DIR/DEBIAN/postrm"

# Documentation
if [ -f "README.md" ]; then
    cp README.md "$BUILD_DIR/usr/share/doc/$PKG_NAME/README.md"
fi

echo -e "${YELLOW}>> Setting correct file permissions...${NC}"
find "$BUILD_DIR" -type d -exec chmod 755 {} +
chmod 755 "$BUILD_DIR/usr/bin/folderlock"
chmod 755 "$BUILD_DIR/DEBIAN/postinst"
chmod 755 "$BUILD_DIR/DEBIAN/postrm"

chmod 644 "$BUILD_DIR/DEBIAN/control"
chmod 644 "$BUILD_DIR/usr/share/nemo/actions/folderlock.nemo_action"
chmod 644 "$BUILD_DIR/usr/share/kservices5/ServiceMenus/folderlock.desktop"
chmod 644 "$BUILD_DIR/usr/share/kio/servicemenus/folderlock.desktop"
chmod 644 "$BUILD_DIR/usr/share/nautilus-python/extensions/folderlock.py"
chmod 644 "$BUILD_DIR/etc/xdg/autostart/folderlock-monitor.desktop"
if [ -f "$BUILD_DIR/usr/share/doc/$PKG_NAME/README.md" ]; then
    chmod 644 "$BUILD_DIR/usr/share/doc/$PKG_NAME/README.md"
fi

echo -e "${YELLOW}>> Building package with dpkg-deb...${NC}"
dpkg-deb --build --root-owner-group "$BUILD_DIR" "$OUTPUT_DEB"

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}  Package built successfully: $OUTPUT_DEB${NC}"
echo -e "${GREEN}====================================================${NC}"

echo -e "\n${BLUE}Package contents:${NC}"
dpkg-deb -c "$OUTPUT_DEB"

echo -e "\n${BLUE}To install the package:${NC}"
echo -e "  ${YELLOW}sudo apt install ./${OUTPUT_DEB}${NC}"

echo -e "\n${BLUE}To remove the package:${NC}"
echo -e "  ${YELLOW}sudo apt remove ${PKG_NAME}${NC}"

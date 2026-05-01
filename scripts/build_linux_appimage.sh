#!/usr/bin/env bash

set -euo pipefail

LOVE_BIN="${LOVE_BIN:-$(command -v love || true)}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$REPO_ROOT/.build/linux"
OUTPUT_ROOT="$REPO_ROOT/$OUTPUT_DIR"
APPDIR="$BUILD_ROOT/Noizemaker.AppDir"
GAME_LOVE="$BUILD_ROOT/noizemaker.love"
LINUXDEPLOY_APPIMAGE="$BUILD_ROOT/linuxdeploy-x86_64.AppImage"
DESKTOP_TEMPLATE="$REPO_ROOT/scripts/linux/noizemaker.desktop"
ICON_TEMPLATE="$REPO_ROOT/scripts/linux/noizemaker.svg"
APPIMAGE_NAME="noizemaker-linux-x86_64.AppImage"
APPIMAGE_PATH="$OUTPUT_ROOT/$APPIMAGE_NAME"

reset_dir() {
    local dir_path="$1"
    rm -rf "$dir_path"
    mkdir -p "$dir_path"
}

assert_file() {
    local file_path="$1"
    local message="$2"
    if [[ ! -f "$file_path" ]]; then
        echo "$message" >&2
        exit 1
    fi
}

download_linuxdeploy() {
    local url="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
    echo "Downloading linuxdeploy from $url"
    curl -fsSL "$url" -o "$LINUXDEPLOY_APPIMAGE"
    chmod +x "$LINUXDEPLOY_APPIMAGE"
}

write_wrapper() {
    local wrapper_path="$APPDIR/usr/bin/noizemaker"
    cat >"$wrapper_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
exec "$USR_DIR/bin/love" "$USR_DIR/share/noizemaker/noizemaker.love" "$@"
EOF
    chmod +x "$wrapper_path"
}

main() {
    assert_file "$LOVE_BIN" "Could not find the LOVE runtime binary at $LOVE_BIN."
    assert_file "$DESKTOP_TEMPLATE" "Missing desktop entry template."
    assert_file "$ICON_TEMPLATE" "Missing icon template."

    reset_dir "$BUILD_ROOT"
    reset_dir "$OUTPUT_ROOT"

    mkdir -p "$APPDIR/usr/bin"
    mkdir -p "$APPDIR/usr/share/noizemaker"
    mkdir -p "$APPDIR/usr/share/applications"
    mkdir -p "$APPDIR/usr/share/icons/hicolor/scalable/apps"
    mkdir -p "$APPDIR/usr/share/doc/noizemaker"

    (
        cd "$REPO_ROOT"
        zip -qr "$GAME_LOVE" main.lua core ui README.md
    )

    cp "$GAME_LOVE" "$APPDIR/usr/share/noizemaker/noizemaker.love"
    cp "$REPO_ROOT/README.md" "$APPDIR/usr/share/doc/noizemaker/README.md"
    cp "$DESKTOP_TEMPLATE" "$APPDIR/usr/share/applications/noizemaker.desktop"
    cp "$ICON_TEMPLATE" "$APPDIR/usr/share/icons/hicolor/scalable/apps/noizemaker.svg"

    write_wrapper
    download_linuxdeploy

    (
        cd "$BUILD_ROOT"
        ARCH=x86_64 "$LINUXDEPLOY_APPIMAGE" --appimage-extract-and-run \
            --appdir "$APPDIR" \
            --executable "$LOVE_BIN" \
            --desktop-file "$APPDIR/usr/share/applications/noizemaker.desktop" \
            --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/noizemaker.svg" \
            --output appimage
    )

    local built_appimage
    built_appimage="$(find "$BUILD_ROOT" -maxdepth 1 -type f -name '*.AppImage' | head -n 1)"
    if [[ -z "$built_appimage" ]]; then
        echo "linuxdeploy did not produce an AppImage." >&2
        exit 1
    fi

    mv "$built_appimage" "$APPIMAGE_PATH"
    chmod +x "$APPIMAGE_PATH"
    sha256sum "$APPIMAGE_PATH" > "$APPIMAGE_PATH.sha256"

    echo "Linux AppImage written to $APPIMAGE_PATH"
}

main "$@"

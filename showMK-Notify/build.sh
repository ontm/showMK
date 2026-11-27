#!/bin/zsh
# 构建 showMK Notify（独立 v0.2），默认生成 arm64 + x86_64 通用版本
set -euo pipefail
ROOT="${0:A:h}"
APP="$ROOT/showMK-Notify.app"
TMP="$ROOT/.build"
MIN_ARM64="14.0"
MIN_X86_64="14.0"
MODE="${1:-universal}"

if [[ "$MODE" == "intel-12.4" ]]; then
    APP="$ROOT/dist/intel-12.4/showMK-Notify.app"
    MIN_X86_64="12.4"
fi

mkdir -p "${APP:h}"
rm -rf "$TMP"
mkdir -p "$TMP"
BUILD_APP="$TMP/showMK-Notify.app"
mkdir -p "$BUILD_APP/Contents/MacOS"

build_arch() {
    local arch="$1"
    local minimum="$2"
    swiftc "$ROOT/Sources/showMKNotify/main.swift" \
        -target "${arch}-apple-macos${minimum}" \
        -framework AppKit \
        -O \
        -o "$TMP/showMK-Notify-${arch}"
}

case "$MODE" in
    universal)
        build_arch arm64 "$MIN_ARM64"
        build_arch x86_64 "$MIN_X86_64"
        lipo -create "$TMP/showMK-Notify-arm64" "$TMP/showMK-Notify-x86_64" \
            -output "$BUILD_APP/Contents/MacOS/showMK-Notify"
        ;;
    intel-12.4)
        build_arch x86_64 "$MIN_X86_64"
        cp "$TMP/showMK-Notify-x86_64" "$BUILD_APP/Contents/MacOS/showMK-Notify"
        ;;
    *)
        print -u2 -- "用法：$0 [universal|intel-12.4]"
        exit 2
        ;;
esac

mkdir -p "$BUILD_APP/Contents/Resources"
cp "$ROOT/Resources/showMK.icns" "$BUILD_APP/Contents/Resources/"
cp "$ROOT/Info.plist" "$BUILD_APP/Contents/Info.plist"
if [[ "$MODE" == "intel-12.4" ]]; then
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 12.4" "$BUILD_APP/Contents/Info.plist"
fi
codesign --force --sign - "$BUILD_APP" >/dev/null 2>&1
/usr/bin/file "$BUILD_APP/Contents/MacOS/showMK-Notify"
rm -rf "$APP"
mv "$BUILD_APP" "$APP"
rm -rf "$TMP"
printf '已构建（%s）：%s\n' "$MODE" "$APP"

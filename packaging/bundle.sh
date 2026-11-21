#!/bin/bash
# Builds build/GTube.app (and build/GTube-macos-arm64.zip) from the release
# build (swift build -c release), with libmpv from Homebrew and the latest
# yt-dlp and deno inside:
#   brew install mpv pkgconf librsvg dylibbundler
#
# The app is signed ad hoc (not notarized): after downloading it, open it with
# right-click → Open, or run: xattr -dr com.apple.quarantine GTube.app
set -Eeuo pipefail
trap 'echo "${BASH_SOURCE[0]}:$LINENO: failed: $BASH_COMMAND" >&2' ERR
cd "$(dirname "$0")/.."

APP_ID=io.github.gtube.mac
BREW=$(brew --prefix)
BUILD=$PWD/build
APP=$BUILD/GTube.app
C=$APP/Contents
VERSION=$(sed -n 's/^public let gtubeVersion = "\(.*\)"/\1/p' Sources/GTubeCore/Lyrics.swift | head -n1)
BIN=$(swift build -c release --show-bin-path)/GTube
[ -x "$BIN" ] || swift build -c release --product GTube

rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources"
cp "$BIN" "$C/MacOS/GTube"

cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>GTube</string>
    <key>CFBundleDisplayName</key><string>GTube</string>
    <key>CFBundleIdentifier</key><string>$APP_ID</string>
    <key>CFBundleExecutable</key><string>GTube</string>
    <key>CFBundleIconFile</key><string>GTube</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>GTube link</string>
            <key>CFBundleURLSchemes</key><array><string>gtube</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# App icon.
iconset=$BUILD/GTube.iconset
rm -rf "$iconset" && mkdir -p "$iconset"
for s in 16 32 128 256 512; do
    rsvg-convert -w $s -h $s Resources/AppIcon.svg -o "$iconset/icon_${s}x${s}.png"
    rsvg-convert -w $((s * 2)) -h $((s * 2)) Resources/AppIcon.svg -o "$iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$iconset" -o "$C/Resources/GTube.icns"

# libmpv and every Homebrew library it needs, into Frameworks.
# (stdin closed: dylibbundler asks on the terminal when it can't find a library)
dylibbundler -of -b -x "$C/MacOS/GTube" -d "$C/Frameworks" -p @executable_path/../Frameworks/ -s "$BREW/lib" </dev/null
# dylibbundler can add its rpath more than once; dyld refuses duplicates.
rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }'; }
for f in "$C/MacOS/GTube" "$C"/Frameworks/*.dylib; do
    for _ in 1 2 3 4 5 6 7 8; do
        dup=$(rpaths "$f" | sort | uniq -d | head -n1)
        if [ -z "$dup" ]; then break; fi
        install_name_tool -delete_rpath "$dup" "$f"
    done
done
if otool -L "$C/MacOS/GTube" "$C"/Frameworks/*.dylib | grep -E "^[[:space:]]+($BREW|/usr/local/(opt|Cellar))"; then
    echo "libraries still point into Homebrew" >&2
    exit 1
fi

# yt-dlp and deno, next to the program (a yt-dlp on the system is preferred).
packaging/fetch-tools.sh macos "$C/MacOS"

# dylibbundler's edits invalidate signatures; Apple Silicon won't load
# unsigned code, so sign what was changed (ad hoc).
codesign --force --sign - "$C"/Frameworks/*.dylib
codesign --force --sign - "$C/MacOS/yt-dlp" "$C/MacOS/deno" || true
codesign --force --sign - "$APP"

rm -f "$BUILD/GTube-macos-arm64.zip"
ditto -c -k --keepParent "$APP" "$BUILD/GTube-macos-arm64.zip"
echo "Built $APP and $BUILD/GTube-macos-arm64.zip"

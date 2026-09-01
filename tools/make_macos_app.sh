#!/usr/bin/env bash
# Package the macOS build into Smash64r.app.
#
# The app opens assets/, gamecontrollerdb.txt and its .rml documents by relative
# path, so they must sit in Contents/Resources and main.cpp chdirs there at
# startup (see macos_prepare_bundle_environment).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:-$ROOT/build-macos}"
OUTDIR="${2:-$ROOT}"
APP="$OUTDIR/Smash64r.app"

[ -x "$BUILD/Smash64r" ] || { echo "error: $BUILD/Smash64r not built" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BUILD/Smash64r" "$APP/Contents/MacOS/"
cp -R "$ROOT/assets" "$APP/Contents/Resources/assets"
cp "$ROOT/gamecontrollerdb.txt" "$APP/Contents/Resources/" 2>/dev/null || true

# Icon: iconutil requires the @2x entries to be exactly double, so resize rather
# than copying one PNG to every slot.
if [ -f "$ROOT/icons/512.png" ]; then
    ICONSET="$(mktemp -d)/Smash64r.iconset"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz "$ROOT/icons/512.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        sips -z $((sz*2)) $((sz*2)) "$ROOT/icons/512.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    mkdir -p "$APP/Contents/Resources"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Smash64r.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Smash64r</string>
    <key>CFBundleDisplayName</key><string>Super Smash Bros: Recompiled</string>
    <key>CFBundleExecutable</key><string>Smash64r</string>
    <key>CFBundleIdentifier</key><string>com.zestydevy.Smash64r</string>
    <key>CFBundleIconFile</key><string>Smash64r</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1.1</string>
    <key>CFBundleVersion</key><string>1.1.1</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST

# Vendor the Homebrew dylibs. sdl2-compat dlopen()s libSDL3.dylib by name and
# searches @loader_path first, so it is not a link-time dependency and has to be
# copied by hand -- dependency walkers miss it entirely.
FW="$APP/Contents/Frameworks"
BIN="$APP/Contents/MacOS/Smash64r"
BREW="$(brew --prefix)"

# Resolve each dylib from the binary's own load commands: `brew --prefix sdl2`
# reports the sdl2-compat keg while the recorded install name is
# /opt/homebrew/opt/sdl2/..., and install_name_tool -change needs an exact match.
for lib in $(otool -L "$BIN" | awk -v p="$BREW" '$1 ~ "^"p {print $1}'); do
    base="$(basename "$lib")"
    cp "$lib" "$FW/$base"
    chmod u+w "$FW/$base"
    install_name_tool -id "@rpath/$base" "$FW/$base"
    install_name_tool -change "$lib" "@rpath/$base" "$BIN"
done

cp "$(brew --prefix sdl3)/lib/libSDL3.0.dylib" "$FW/libSDL3.dylib"
chmod u+w "$FW/libSDL3.dylib"
install_name_tool -id @loader_path/libSDL3.dylib "$FW/libSDL3.dylib"

# Rewrite any Homebrew references between the vendored dylibs themselves
# (freetype -> libpng, for example).
for dylib in "$FW"/*.dylib; do
    for dep in $(otool -L "$dylib" | awk -v p="$BREW" '$1 ~ "^"p {print $1}'); do
        depbase="$(basename "$dep")"
        if [ ! -f "$FW/$depbase" ]; then
            cp "$dep" "$FW/$depbase"
            chmod u+w "$FW/$depbase"
            install_name_tool -id "@rpath/$depbase" "$FW/$depbase"
        fi
        install_name_tool -change "$dep" "@loader_path/$depbase" "$dylib"
    done
done

install_name_tool -add_rpath @executable_path/../Frameworks "$BIN" 2>/dev/null || true

# dyld searches LC_RPATH entries in order, so an @rpath load command is only as
# good as that list. Drop every absolute Homebrew rpath or the app silently
# keeps loading the Homebrew copies.
while otool -l "$BIN" | grep -A2 LC_RPATH | grep -q "path $BREW"; do
    RP="$(otool -l "$BIN" | grep -A2 LC_RPATH | awk -v p="$BREW" '$1=="path" && index($2,p)==1 {print $2; exit}')"
    [ -n "$RP" ] || break
    install_name_tool -delete_rpath "$RP" "$BIN"
done

# install_name_tool invalidates arm64 signatures; re-sign inside out.
codesign --force --sign - "$FW"/*.dylib
codesign --force --sign - "$BIN"
codesign --force --sign - "$APP"

if otool -L "$BIN" "$FW"/*.dylib | grep -q "$BREW"; then
    echo "error: bundle still references Homebrew paths" >&2; exit 1
fi
if otool -l "$BIN" | grep -A2 LC_RPATH | grep -q "path $BREW"; then
    echo "error: bundle still has a Homebrew LC_RPATH" >&2; exit 1
fi
echo "built $APP"

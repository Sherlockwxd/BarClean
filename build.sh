#!/bin/zsh
set -e

cd "${0:A:h}"
app="build/BarClean.app"
iconset="build/BarClean.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp NOTICE.md "$app/Contents/Resources/NOTICE.md"
# iconutil 需要各尺寸及其 2x 版本，统一从当前应用图标生成。
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/BarClean-icon.png \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Resources/BarClean-icon.png \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/BarClean.icns"
swiftc -O -swift-version 5 -target arm64-apple-macosx27.0 \
    -framework AppKit \
    -framework ApplicationServices \
    -framework ServiceManagement \
    Sources/*.swift -o "$app/Contents/MacOS/BarClean"
codesign --force --sign - "$app"
print "已生成 ${PWD}/$app"

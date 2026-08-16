#!/bin/sh
# Builds kagami.app into ~/Applications and links the CLI.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/kagami.app"

# icon: regenerate only if missing
if [ ! -f kagami.icns ]; then
    swift icongen.swift
    rm -rf kagami.iconset && mkdir kagami.iconset
    for s in 16 32 128 256 512; do
        sips -z $s $s icon_1024.png --out "kagami.iconset/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d icon_1024.png --out "kagami.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns kagami.iconset -o kagami.icns
    rm -rf kagami.iconset icon_1024.png
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/kagami" kagami.swift
cp Info.plist "$APP/Contents/"
cp kagami.icns "$APP/Contents/Resources/"
codesign --force -s - "$APP"
mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/kagami" "$HOME/.local/bin/kagami"
echo "built $APP (CLI: kagami)"
